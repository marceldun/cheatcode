import base64, importlib, io, json, os, re, tempfile, unittest
from unittest.mock import patch
from pathlib import Path
from cryptography.fernet import Fernet
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

class StoreTest(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.tmp=tempfile.TemporaryDirectory(); os.environ.update(STORE_DATA_DIR=cls.tmp.name,STORE_ENCRYPTION_KEY=Fernet.generate_key().decode(),STORE_SECRET_KEY='test-secret',STORE_ADMIN_USER='marcel',STORE_ADMIN_PASSWORD='VeryStrongTestPass123',STORE_HTTPS='0')
  import app; cls.mod=app; app.init_db(); app.app.config['TESTING']=True; cls.client=app.app.test_client()
 @classmethod
 def tearDownClass(cls): cls.tmp.cleanup()
 def csrf(self,path):
  html=self.client.get(path).get_data(as_text=True); return re.search(r'name="csrf_token" value="([^"]+)"',html).group(1)
 def login(self):
  token=self.csrf('/admin/login'); r=self.client.post('/admin/login',data={'csrf_token':token,'username':'marcel','password':'VeryStrongTestPass123'}); self.assertEqual(r.status_code,302)
 def test_01_public_layout_health_and_headers(self):
  r=self.client.get('/'); self.assertEqual(r.status_code,200); self.assertIn('选择商品',r.get_data(as_text=True)); self.assertEqual(r.headers['X-Frame-Options'],'DENY')
  self.assertEqual(self.client.get('/healthz').json,{'ok':True,'db':1})
 def test_015_admin_direct_qr_upload_and_public_display(self):
  import qrcode
  self.login(); token=self.csrf('/admin')
  def png(value):
   out=io.BytesIO(); qrcode.make(value).resize((320,320)).save(out,format='PNG'); out.seek(0); return out
  r=self.client.post('/admin/payment-qr',data={'csrf_token':token,'alipay_qr_file':(png('alipay-test'),'alipay.png'),'wechat_qr_file':(png('wechat-test'),'wechat.png'),'support_qr_file':(png('support-test'),'support.png')},content_type='multipart/form-data',follow_redirects=True)
  text=r.get_data(as_text=True); self.assertIn('支付宝、微信支付、客服微信收款二维码已上传并启用',text); self.assertIn('/payment-assets/alipay.png',text); self.assertIn('/payment-assets/wechat.png',text); self.assertIn('/payment-assets/support.png',text)
  for kind in ('alipay','wechat','support'):
   img=self.client.get(f'/payment-assets/{kind}.png'); self.assertEqual(img.status_code,200); self.assertEqual(img.mimetype,'image/png'); self.assertGreater(len(img.data),500); img.close()
  with self.mod.app.app_context(): self.mod.db().execute("INSERT OR REPLACE INTO settings VALUES('wechat_id','wx-marcel')")
  home=self.client.get('/').get_data(as_text=True); self.assertIn('wx-marcel',home); self.assertIn('/payment-assets/support.png',home)
  self.client.get('/admin/logout')
 def test_02_admin_inventory_order_delivery_and_secure_lookup(self):
  self.login(); token=self.csrf('/admin')
  secret='LEGAL-LICENSE-CODE-ABC-999'
  r=self.client.post('/admin/inventory',data={'csrf_token':token,'product_id':'1','items':secret},follow_redirects=True); self.assertIn('加密导入 1 条库存',r.get_data(as_text=True))
  raw=Path(self.tmp.name,'store.db').read_bytes(); self.assertNotIn(secret.encode(),raw)
  self.client.get('/admin/logout')
  token=self.csrf('/buy/1'); r=self.client.post('/buy/1',data={'csrf_token':token,'contact':'+8613800138000','payment_method':'alipay'}); self.assertEqual(r.status_code,302)
  url=r.headers['Location']; oid=re.search(r'/order/([^?]+)',url).group(1); code=re.search(r'code=([^&]+)',url).group(1)
  self.login(); token=self.csrf('/admin'); self.client.post('/admin/order/fulfill',data={'csrf_token':token,'order_id':oid})
  self.client.get('/admin/logout'); page=self.client.get(url).get_data(as_text=True); self.assertIn(secret,page)
  token=self.csrf('/lookup'); found=self.client.post('/lookup',data={'csrf_token':token,'contact':'+86 138-0013-8000'}); text=found.get_data(as_text=True); self.assertIn(oid,text); self.assertIn('已发货',text); self.assertNotIn(secret,text)
 def test_03_payment_crypto(self):
  import payments
  key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
  priv=key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()).decode()
  pub=key.public_key().public_bytes(serialization.Encoding.PEM,serialization.PublicFormat.SubjectPublicKeyInfo).decode()
  sig=payments.rsa_sign(priv,'hello'); self.assertTrue(payments.rsa_verify(pub,'hello',sig)); self.assertFalse(payments.rsa_verify(pub,'changed',sig))
  class Reply:
   def raise_for_status(self): pass
   def json(self): return {'alipay_trade_precreate_response':{'code':'10000','qr_code':'https://qr.alipay.test/order'}}
  cfg={'alipay_app_id':'app','alipay_private_key':priv}
  with patch('payments.requests.post',return_value=Reply()) as post:
   code=payments.alipay_precreate_code(cfg,'ORDER-1','合法商品',1234,'https://shop.example')
   self.assertEqual(code,'https://qr.alipay.test/order')
   sent=post.call_args.kwargs['data']; biz=json.loads(sent['biz_content']); self.assertEqual(biz['total_amount'],'12.34'); self.assertEqual(biz['out_trade_no'],'ORDER-1')
  api='0123456789abcdef0123456789abcdef'; nonce=b'123456789012'; aad=b'certificate'; obj={'out_trade_no':'X','trade_state':'SUCCESS'}
  cipher=AESGCM(api.encode()).encrypt(nonce,json.dumps(obj).encode(),aad)
  got=payments.wechat_decrypt({'wechat_apiv3_key':api},{'nonce':nonce.decode(),'associated_data':aad.decode(),'ciphertext':base64.b64encode(cipher).decode()}); self.assertEqual(got,obj)
 def test_035_checkout_redirects_to_fixed_amount_dynamic_qr(self):
  with self.mod.app.app_context():
   c=self.mod.db(); c.execute("INSERT OR REPLACE INTO settings VALUES('payment_mode','official')"); c.execute("INSERT OR REPLACE INTO settings VALUES('base_url','https://shop.example')"); c.execute("INSERT OR REPLACE INTO settings VALUES('alipay_app_id','app')")
   c.execute("INSERT OR REPLACE INTO secret_settings VALUES('alipay_private_key',?)",(self.mod.enc('private'),)); c.execute("INSERT OR REPLACE INTO secret_settings VALUES('alipay_public_key',?)",(self.mod.enc('public'),))
  token=self.csrf('/buy/2')
  with patch('app.alipay_precreate_code',return_value='https://qr.alipay.test/fixed') as create:
   r=self.client.post('/buy/2',data={'csrf_token':token,'contact':'pay@example.com','payment_method':'alipay'}); self.assertEqual(r.status_code,302)
   self.assertEqual(create.call_args.args[3],1290)
  page=self.client.get(r.headers['Location']).get_data(as_text=True); self.assertIn('官方一单一码',page); self.assertIn('12.90',page)
  oid=re.search(r'/order/([^?]+)',r.headers['Location']).group(1); qr=self.client.get(f'/payment/qr/{oid}.png'); self.assertEqual(qr.status_code,200); self.assertEqual(qr.mimetype,'image/png'); qr.close()
 def test_04_signed_alipay_callback_auto_delivery(self):
  import payments
  key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
  priv=key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()).decode()
  pub=key.public_key().public_bytes(serialization.Encoding.PEM,serialization.PublicFormat.SubjectPublicKeyInfo).decode()
  oid='ALIPAY-TEST-001'; secret='ALIPAY-AUTO-DELIVERY-CODE'
  with self.mod.app.app_context():
   c=self.mod.db(); c.execute("INSERT OR REPLACE INTO settings VALUES('alipay_app_id','test-app')")
   c.execute("INSERT OR REPLACE INTO secret_settings VALUES('alipay_public_key',?)",(self.mod.enc(pub),))
   c.execute("INSERT INTO inventory(product_id,payload,created_at) VALUES(2,?,?)",(self.mod.enc(secret),self.mod.now()))
   c.execute("INSERT INTO orders VALUES(?,?,?,?,?,?,?,?,?,?,?)",(oid,'pay@example.com',2,1290,'alipay','awaiting_payment',self.mod.token_hash('lookup'),None,None,self.mod.now(),None))
  form={'app_id':'test-app','out_trade_no':oid,'total_amount':'12.90','trade_no':'TRADE-1','trade_status':'TRADE_SUCCESS','sign_type':'RSA2'}
  canonical='&'.join(f'{k}={form[k]}' for k in sorted(form) if k!='sign_type')
  form['sign']=payments.rsa_sign(priv,canonical)
  r=self.client.post('/payment/alipay/notify',data=form); self.assertEqual(r.status_code,200); self.assertEqual(r.get_data(as_text=True),'success')
  status=self.client.get('/api/order-status/'+oid+'?code=lookup'); self.assertEqual(status.json['status'],'delivered')
  with self.mod.app.app_context():
   row=self.mod.db().execute('SELECT * FROM orders WHERE id=?',(oid,)).fetchone(); self.assertEqual(row['status'],'delivered'); self.assertEqual(self.mod.dec(row['delivery']),secret)
 def test_05_signed_wechat_callback_auto_delivery(self):
  import payments, time
  key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
  priv=key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()).decode()
  pub=key.public_key().public_bytes(serialization.Encoding.PEM,serialization.PublicFormat.SubjectPublicKeyInfo).decode()
  api='0123456789abcdef0123456789abcdef'; oid='WECHAT-TEST-001'; secret='WECHAT-AUTO-DELIVERY-CODE'; nonce=b'123456789012'; aad=b'transaction'
  with self.mod.app.app_context():
   c=self.mod.db(); c.execute("INSERT OR REPLACE INTO secret_settings VALUES('wechat_platform_public_key',?)",(self.mod.enc(pub),)); c.execute("INSERT OR REPLACE INTO secret_settings VALUES('wechat_apiv3_key',?)",(self.mod.enc(api),))
   c.execute("INSERT INTO inventory(product_id,payload,created_at) VALUES(3,?,?)",(self.mod.enc(secret),self.mod.now()))
   c.execute("INSERT INTO orders VALUES(?,?,?,?,?,?,?,?,?,?,?)",(oid,'wx@example.com',3,1990,'wechat','awaiting_payment',self.mod.token_hash('lookup'),None,None,self.mod.now(),None))
  data={'out_trade_no':oid,'trade_state':'SUCCESS','transaction_id':'WX-1','amount':{'total':1990}}
  cipher=AESGCM(api.encode()).encrypt(nonce,json.dumps(data,separators=(',',':')).encode(),aad)
  body=json.dumps({'resource':{'nonce':nonce.decode(),'associated_data':aad.decode(),'ciphertext':base64.b64encode(cipher).decode()}},separators=(',',':'))
  ts=str(int(time.time())); n='notify-nonce'; sig=payments.rsa_sign(priv,f'{ts}\n{n}\n{body}\n')
  r=self.client.post('/payment/wechat/notify',data=body,content_type='application/json',headers={'Wechatpay-Timestamp':ts,'Wechatpay-Nonce':n,'Wechatpay-Signature':sig}); self.assertEqual(r.status_code,200)
  status=self.client.get('/api/order-status/'+oid+'?code=lookup'); self.assertEqual(status.json['status'],'delivered')
  with self.mod.app.app_context():
   row=self.mod.db().execute('SELECT * FROM orders WHERE id=?',(oid,)).fetchone(); self.assertEqual(row['status'],'delivered'); self.assertEqual(self.mod.dec(row['delivery']),secret)

if __name__=='__main__': unittest.main(verbosity=2)

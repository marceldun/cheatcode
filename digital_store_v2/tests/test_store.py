import base64, importlib, json, os, re, tempfile, unittest
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
 def test_02_admin_inventory_order_delivery_and_secure_lookup(self):
  self.login(); token=self.csrf('/admin')
  secret='LEGAL-LICENSE-CODE-ABC-999'
  r=self.client.post('/admin/inventory',data={'csrf_token':token,'product_id':'1','items':secret},follow_redirects=True); self.assertIn('加密导入 1 条库存',r.get_data(as_text=True))
  raw=Path(self.tmp.name,'store.db').read_bytes(); self.assertNotIn(secret.encode(),raw)
  self.client.get('/admin/logout')
  token=self.csrf('/buy/1'); r=self.client.post('/buy/1',data={'csrf_token':token,'email':'buyer@example.com','payment_method':'alipay'}); self.assertEqual(r.status_code,302)
  url=r.headers['Location']; oid=re.search(r'/order/([^?]+)',url).group(1); code=re.search(r'code=([^&]+)',url).group(1)
  self.login(); token=self.csrf('/admin'); self.client.post('/admin/order/fulfill',data={'csrf_token':token,'order_id':oid})
  self.client.get('/admin/logout'); page=self.client.get(url).get_data(as_text=True); self.assertIn(secret,page)
  token=self.csrf('/lookup'); bad=self.client.post('/lookup',data={'csrf_token':token,'email':'buyer@example.com','order_id':oid,'lookup_code':'wrong'},follow_redirects=True); self.assertNotIn(secret,bad.get_data(as_text=True))
  token=self.csrf('/lookup'); good=self.client.post('/lookup',data={'csrf_token':token,'email':'buyer@example.com','order_id':oid,'lookup_code':code}); self.assertIn(secret,good.get_data(as_text=True))
 def test_03_payment_crypto(self):
  import payments
  key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
  priv=key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()).decode()
  pub=key.public_key().public_bytes(serialization.Encoding.PEM,serialization.PublicFormat.SubjectPublicKeyInfo).decode()
  sig=payments.rsa_sign(priv,'hello'); self.assertTrue(payments.rsa_verify(pub,'hello',sig)); self.assertFalse(payments.rsa_verify(pub,'changed',sig))
  api='0123456789abcdef0123456789abcdef'; nonce=b'123456789012'; aad=b'certificate'; obj={'out_trade_no':'X','trade_state':'SUCCESS'}
  cipher=AESGCM(api.encode()).encrypt(nonce,json.dumps(obj).encode(),aad)
  got=payments.wechat_decrypt({'wechat_apiv3_key':api},{'nonce':nonce.decode(),'associated_data':aad.decode(),'ciphertext':base64.b64encode(cipher).decode()}); self.assertEqual(got,obj)
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
  with self.mod.app.app_context():
   row=self.mod.db().execute('SELECT * FROM orders WHERE id=?',(oid,)).fetchone(); self.assertEqual(row['status'],'delivered'); self.assertEqual(self.mod.dec(row['delivery']),secret)

if __name__=='__main__': unittest.main(verbosity=2)

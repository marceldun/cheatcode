import base64, json, secrets, time
from urllib.parse import urlencode
import requests
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

ALIPAY_GATEWAY="https://openapi.alipay.com/gateway.do"

def _private(pem): return serialization.load_pem_private_key(pem.encode(),password=None)
def _public(pem): return serialization.load_pem_public_key(pem.encode())
def rsa_sign(private_pem,message):
    raw=_private(private_pem).sign(message.encode(),padding.PKCS1v15(),hashes.SHA256())
    return base64.b64encode(raw).decode()
def rsa_verify(public_pem,message,signature):
    try: _public(public_pem).verify(base64.b64decode(signature),message.encode(),padding.PKCS1v15(),hashes.SHA256()); return True
    except Exception: return False

def alipay_page_url(cfg,order_id,title,amount,base_url):
    params={"app_id":cfg["alipay_app_id"],"method":"alipay.trade.page.pay","format":"JSON","charset":"utf-8",
            "sign_type":"RSA2","timestamp":time.strftime("%Y-%m-%d %H:%M:%S"),"version":"1.0",
            "notify_url":base_url+"/payment/alipay/notify","return_url":base_url+f"/payment/return/{order_id}",
            "biz_content":json.dumps({"out_trade_no":order_id,"product_code":"FAST_INSTANT_TRADE_PAY","total_amount":f"{amount/100:.2f}","subject":title},ensure_ascii=False,separators=(",",":"))}
    canonical="&".join(f"{k}={params[k]}" for k in sorted(params))
    params["sign"]=rsa_sign(cfg["alipay_private_key"],canonical)
    return ALIPAY_GATEWAY+"?"+urlencode(params)

def alipay_precreate_code(cfg,order_id,title,amount,base_url):
    """Create an official face-to-face QR whose amount is fixed by Alipay."""
    params={"app_id":cfg["alipay_app_id"],"method":"alipay.trade.precreate","format":"JSON","charset":"utf-8",
            "sign_type":"RSA2","timestamp":time.strftime("%Y-%m-%d %H:%M:%S"),"version":"1.0",
            "notify_url":base_url+"/payment/alipay/notify",
            "biz_content":json.dumps({"out_trade_no":order_id,"total_amount":f"{amount/100:.2f}","subject":title},ensure_ascii=False,separators=(",",":"))}
    canonical="&".join(f"{k}={params[k]}" for k in sorted(params))
    params["sign"]=rsa_sign(cfg["alipay_private_key"],canonical)
    response=requests.post(ALIPAY_GATEWAY,data=params,timeout=20); response.raise_for_status()
    data=response.json().get("alipay_trade_precreate_response",{})
    if data.get("code")!="10000" or not data.get("qr_code"):
        raise RuntimeError(data.get("sub_msg") or data.get("msg") or "Alipay precreate failed")
    return data["qr_code"]

def alipay_verify(cfg,form):
    params={k:v for k,v in form.items() if k not in ("sign","sign_type") and v!=""}
    canonical="&".join(f"{k}={params[k]}" for k in sorted(params))
    return rsa_verify(cfg["alipay_public_key"],canonical,form.get("sign",""))

def wechat_authorization(cfg,method,path,body):
    ts=str(int(time.time())); nonce=secrets.token_hex(16); message=f"{method}\n{path}\n{ts}\n{nonce}\n{body}\n"
    sig=rsa_sign(cfg["wechat_private_key"],message)
    auth=(f'WECHATPAY2-SHA256-RSA2048 mchid="{cfg["wechat_mchid"]}",nonce_str="{nonce}",'
          f'timestamp="{ts}",serial_no="{cfg["wechat_serial"]}",signature="{sig}"')
    return auth

def wechat_native_code(cfg,order_id,title,amount,base_url):
    path="/v3/pay/transactions/native"
    data={"appid":cfg["wechat_appid"],"mchid":cfg["wechat_mchid"],"description":title[:127],"out_trade_no":order_id,
          "notify_url":base_url+"/payment/wechat/notify","amount":{"total":amount,"currency":"CNY"}}
    body=json.dumps(data,ensure_ascii=False,separators=(",",":"))
    r=requests.post("https://api.mch.weixin.qq.com"+path,data=body.encode(),headers={"Authorization":wechat_authorization(cfg,"POST",path,body),"Accept":"application/json","Content-Type":"application/json","User-Agent":"MarcelDigitalStore/1.0"},timeout=20)
    r.raise_for_status(); return r.json()["code_url"]

def wechat_verify_header(cfg,headers,body):
    message=f'{headers.get("Wechatpay-Timestamp","")}\n{headers.get("Wechatpay-Nonce","")}\n{body}\n'
    return rsa_verify(cfg["wechat_platform_public_key"],message,headers.get("Wechatpay-Signature",""))
def wechat_decrypt(cfg,resource):
    plain=AESGCM(cfg["wechat_apiv3_key"].encode()).decrypt(resource["nonce"].encode(),base64.b64decode(resource["ciphertext"]),resource.get("associated_data","").encode())
    return json.loads(plain)

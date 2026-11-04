import base64, hashlib, hmac, io, json, os, re, secrets, sqlite3, time, uuid
from datetime import datetime, timezone
from functools import wraps
from pathlib import Path
from urllib.parse import urlencode

from cryptography.fernet import Fernet
from flask import Flask, abort, flash, g, jsonify, redirect, render_template, request, send_file, session, url_for
import qrcode
from PIL import Image, UnidentifiedImageError
from werkzeug.security import check_password_hash, generate_password_hash
from payments import alipay_precreate_code, alipay_verify, wechat_native_code, wechat_verify_header, wechat_decrypt

BASE = Path(os.environ.get("STORE_DATA_DIR", "/var/lib/marcel-store"))
BASE.mkdir(parents=True, exist_ok=True)
DB_PATH = BASE / "store.db"
QR_DIR = BASE / "payment-assets"
QR_DIR.mkdir(parents=True, exist_ok=True)
KEY = os.environ.get("STORE_ENCRYPTION_KEY", "").encode()
if not KEY:
    raise RuntimeError("STORE_ENCRYPTION_KEY is required")
fernet = Fernet(KEY)

app = Flask(__name__)
app.secret_key = os.environ["STORE_SECRET_KEY"]
app.config.update(SESSION_COOKIE_HTTPONLY=True, SESSION_COOKIE_SAMESITE="Lax",
                  SESSION_COOKIE_SECURE=os.environ.get("STORE_HTTPS", "1") == "1",
                  MAX_CONTENT_LENGTH=8 * 1024 * 1024)
EMAIL_RE = re.compile(r"^[^\s@]+@[^\s@]+\.[^\s@]+$")
PHONE_RE = re.compile(r"^\+?[0-9]{6,20}$")
RATE = {}


def now(): return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
def enc(v): return fernet.encrypt(v.encode()).decode()
def dec(v): return fernet.decrypt(v.encode()).decode()
def token_hash(v): return hashlib.sha256(v.encode()).hexdigest()

def db():
    if "db" not in g:
        g.db = sqlite3.connect(DB_PATH, timeout=15, isolation_level=None)
        g.db.row_factory = sqlite3.Row
        g.db.execute("PRAGMA journal_mode=WAL")
        g.db.execute("PRAGMA foreign_keys=ON")
        g.db.execute("PRAGMA busy_timeout=15000")
    return g.db

@app.teardown_appcontext
def close_db(_=None):
    conn = g.pop("db", None)
    if conn: conn.close()

def init_db():
    conn = sqlite3.connect(DB_PATH)
    conn.executescript("""
    PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;
    CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS admins(username TEXT PRIMARY KEY, password_hash TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS secret_settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS products(
      id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, description TEXT NOT NULL DEFAULT '',
      price_cents INTEGER NOT NULL CHECK(price_cents>=0), category TEXT NOT NULL DEFAULT '数字商品',
      active INTEGER NOT NULL DEFAULT 1, sort_order INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS inventory(
      id INTEGER PRIMARY KEY AUTOINCREMENT, product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE,
      payload TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'available', order_id TEXT, created_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS orders(
      id TEXT PRIMARY KEY, email TEXT NOT NULL, product_id INTEGER NOT NULL REFERENCES products(id),
      amount_cents INTEGER NOT NULL, payment_method TEXT NOT NULL, status TEXT NOT NULL,
      lookup_hash TEXT NOT NULL, delivery TEXT, trade_no TEXT, created_at TEXT NOT NULL, paid_at TEXT);
    CREATE INDEX IF NOT EXISTS idx_orders_email ON orders(email);
    CREATE INDEX IF NOT EXISTS idx_inventory_available ON inventory(product_id,status);
    """)
    defaults={"site_title":"FB 数字商城","site_subtitle":"正版授权数字商品 · 安全快速交付",
              "icon_text":"FB","contact":"请在后台填写客服联系方式","notice":"下单前请确认商品说明",
              "alipay_qr":"","wechat_qr":"","support_qr":"","wechat_id":"",
              "payment_mode":"manual","base_url":""}
    for k,v in defaults.items(): conn.execute("INSERT OR IGNORE INTO settings VALUES(?,?)",(k,v))
    username=os.environ.get("STORE_ADMIN_USER","marcel")
    password=os.environ.get("STORE_ADMIN_PASSWORD")
    if password:
        # The one-click installer is an authenticated root action. Updating here makes a
        # failed/partial previous installation recover with the password just entered.
        conn.execute("INSERT INTO admins VALUES(?,?) ON CONFLICT(username) DO UPDATE SET password_hash=excluded.password_hash",(username,generate_password_hash(password,method="scrypt")))
    if conn.execute("SELECT count(*) FROM products").fetchone()[0] == 0:
        for i,(name,desc,price,cat) in enumerate([
          ("软件会员兑换码","购买后自动发放一枚合法兑换码",990,"会员服务"),
          ("邮箱服务激活码","用于已授权邮箱服务的激活码",1290,"数字服务"),
          ("美区网络服务激活码","合法网络服务套餐激活码",1990,"网络服务"),
          ("印度区网络服务激活码","合法网络服务套餐激活码",1690,"网络服务")]):
            conn.execute("INSERT INTO products(name,description,price_cents,category,sort_order,created_at) VALUES(?,?,?,?,?,?)",(name,desc,price,cat,i,now()))
    conn.commit(); conn.close()

def settings(): return {r["key"]:r["value"] for r in db().execute("SELECT * FROM settings")}
def normalize_contact(value):
    value=value.strip().lower()
    if EMAIL_RE.match(value): return value
    phone=re.sub(r"[\s()-]","",value)
    return phone if PHONE_RE.match(phone) else ""
def payment_config():
    cfg=settings()
    for r in db().execute("SELECT * FROM secret_settings"):
        try: cfg[r["key"]]=dec(r["value"])
        except Exception: cfg[r["key"]]=""
    return cfg
def csrf():
    if "csrf" not in session: session["csrf"]=secrets.token_urlsafe(24)
    return session["csrf"]
app.jinja_env.globals.update(csrf_token=csrf, site_settings=settings)

def verify_csrf():
    if not hmac.compare_digest(session.get("csrf",""), request.form.get("csrf_token","")): abort(400)

def limited(bucket, limit=8, window=300):
    key=(bucket,request.headers.get("CF-Connecting-IP") or request.remote_addr)
    t=time.time(); items=[x for x in RATE.get(key,[]) if t-x<window]
    if len(items)>=limit: return True
    items.append(t); RATE[key]=items; return False

def admin_required(fn):
    @wraps(fn)
    def wrapped(*a,**kw):
        if not session.get("admin"): return redirect(url_for("admin_login",next=request.path))
        return fn(*a,**kw)
    return wrapped

def fulfill(order_id, trade_no=""):
    conn=db(); conn.execute("BEGIN IMMEDIATE")
    try:
        order=conn.execute("SELECT * FROM orders WHERE id=?",(order_id,)).fetchone()
        if not order: raise ValueError("order not found")
        if order["status"] in ("delivered","paid_out_of_stock"): conn.commit(); return order["status"]
        item=conn.execute("SELECT * FROM inventory WHERE product_id=? AND status='available' ORDER BY id LIMIT 1",(order["product_id"],)).fetchone()
        if item:
            conn.execute("UPDATE inventory SET status='sold',order_id=? WHERE id=? AND status='available'",(order_id,item["id"]))
            conn.execute("UPDATE orders SET status='delivered',delivery=?,trade_no=?,paid_at=? WHERE id=?",(item["payload"],trade_no,now(),order_id))
            status="delivered"
        else:
            conn.execute("UPDATE orders SET status='paid_out_of_stock',trade_no=?,paid_at=? WHERE id=?",(trade_no,now(),order_id)); status="paid_out_of_stock"
        conn.commit(); return status
    except: conn.rollback(); raise

@app.after_request
def headers(resp):
    resp.headers["X-Content-Type-Options"]="nosniff"; resp.headers["X-Frame-Options"]="DENY"
    resp.headers["Referrer-Policy"]="same-origin"
    resp.headers["Content-Security-Policy"]="default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' https: data:; script-src 'self' 'unsafe-inline'"
    if request.path.startswith('/static/'): resp.headers["Cache-Control"]="public,max-age=31536000,immutable"
    return resp

@app.get("/")
def index():
    products=db().execute("""SELECT p.*,(SELECT count(*) FROM inventory i WHERE i.product_id=p.id AND i.status='available') stock
                           FROM products p WHERE active=1 ORDER BY sort_order,id""").fetchall()
    return render_template("index.html",products=products)

@app.route("/buy/<int:pid>",methods=["GET","POST"])
def buy(pid):
    product=db().execute("SELECT * FROM products WHERE id=? AND active=1",(pid,)).fetchone()
    if not product: abort(404)
    if request.method=="POST":
        verify_csrf(); email=normalize_contact(request.form.get("contact","")); method=request.form.get("payment_method","")
        if not email: flash("请输入正确的邮箱或手机号"); return redirect(request.url)
        if method not in ("alipay","wechat"): abort(400)
        cfg=payment_config(); base=cfg.get("base_url","").rstrip("/")
        if cfg.get("payment_mode")=="official":
            required=("alipay_app_id","alipay_private_key","alipay_public_key") if method=="alipay" else ("wechat_appid","wechat_mchid","wechat_serial","wechat_private_key","wechat_apiv3_key")
            if not base or not all(cfg.get(k) for k in required):
                flash("该官方支付方式尚未配置完整，请选择其他方式或联系客服"); return redirect(request.url)
        oid=datetime.now().strftime("%Y%m%d%H%M%S")+secrets.token_hex(4).upper(); lookup=secrets.token_urlsafe(8)
        db().execute("INSERT INTO orders VALUES(?,?,?,?,?,?,?,?,?,?,?)",(oid,email,pid,product["price_cents"],method,"awaiting_payment",token_hash(lookup),None,None,now(),None))
        session[f"order_{oid}"]=lookup
        try:
            if cfg.get("payment_mode")=="official" and base:
                if method=="alipay" and all(cfg.get(k) for k in ("alipay_app_id","alipay_private_key","alipay_public_key")):
                    session[f"alipay_{oid}"]=alipay_precreate_code(cfg,oid,product["name"],product["price_cents"],base)
                if method=="wechat" and all(cfg.get(k) for k in ("wechat_appid","wechat_mchid","wechat_serial","wechat_private_key","wechat_apiv3_key")):
                    session[f"wechat_{oid}"]=wechat_native_code(cfg,oid,product["name"],product["price_cents"],base)
        except Exception as exc:
            app.logger.exception("official payment create failed: %s",exc)
            db().execute("DELETE FROM orders WHERE id=?",(oid,)); session.pop(f"order_{oid}",None)
            flash("官方支付暂时不可用，没有创建无效订单，请稍后重试或联系客服")
            return redirect(request.url)
        return redirect(url_for("order",oid=oid,code=lookup))
    return render_template("buy.html",product=product)

@app.get("/order/<oid>")
def order(oid):
    row=db().execute("SELECT o.*,p.name FROM orders o JOIN products p ON p.id=o.product_id WHERE o.id=?",(oid,)).fetchone()
    if not row: abort(404)
    code=request.args.get("code") or session.get(f"order_{oid}","")
    authorized=bool(code and hmac.compare_digest(token_hash(code),row["lookup_hash"]))
    delivery=dec(row["delivery"]) if authorized and row["delivery"] else None
    return render_template("order.html",order=row,authorized=authorized,delivery=delivery,code=code,settings=settings(),official_qr=bool(session.get(f"alipay_{oid}") or session.get(f"wechat_{oid}")))

@app.get("/api/order-status/<oid>")
def order_status(oid):
    row=db().execute("SELECT status,lookup_hash FROM orders WHERE id=?",(oid,)).fetchone()
    code=request.args.get("code") or session.get(f"order_{oid}","")
    if not row or not code or not hmac.compare_digest(token_hash(code),row["lookup_hash"]): abort(404)
    return jsonify(status=row["status"])

@app.get("/payment/qr/<oid>.png")
def payment_qr(oid):
    value=session.get(f"alipay_{oid}") or session.get(f"wechat_{oid}")
    if not value or not session.get(f"order_{oid}"): abort(404)
    image=qrcode.make(value); buf=io.BytesIO(); image.save(buf,format="PNG"); buf.seek(0)
    return send_file(buf,mimetype="image/png",max_age=60)

@app.get("/payment-assets/<kind>.png")
def payment_asset(kind):
    if kind not in ("alipay","wechat","support"): abort(404)
    path=QR_DIR/f"{kind}.png"
    if not path.is_file(): abort(404)
    return send_file(path,mimetype="image/png",max_age=300,conditional=True)

@app.route("/lookup",methods=["GET","POST"])
def lookup():
    results=[]
    if request.method=="POST":
        verify_csrf()
        if limited("lookup",10,300): abort(429)
        contact=normalize_contact(request.form.get("contact",""))
        if not contact: flash("请输入正确的邮箱或手机号")
        else:
            results=db().execute("SELECT o.id,o.amount_cents,o.status,o.created_at,o.paid_at,p.name FROM orders o JOIN products p ON p.id=o.product_id WHERE o.email=? ORDER BY o.created_at DESC LIMIT 50",(contact,)).fetchall()
            if not results: flash("没有找到该邮箱或手机号的订单")
    return render_template("lookup.html",results=results)

@app.route("/admin/login",methods=["GET","POST"])
def admin_login():
    if request.method=="POST":
        verify_csrf()
        if limited("admin",6,600): abort(429)
        row=db().execute("SELECT * FROM admins WHERE username=?",(request.form.get("username",""),)).fetchone()
        if row and check_password_hash(row["password_hash"],request.form.get("password","")):
            session.clear(); session["admin"]=row["username"]; csrf(); return redirect(url_for("admin"))
        flash("账号或密码错误")
    return render_template("admin_login.html")

@app.get("/admin/logout")
def admin_logout(): session.clear(); return redirect(url_for("index"))

@app.get("/admin")
@admin_required
def admin():
    products=db().execute("""SELECT p.*,(SELECT count(*) FROM inventory i WHERE i.product_id=p.id AND i.status='available') stock FROM products p ORDER BY sort_order,id""").fetchall()
    orders=db().execute("SELECT o.*,p.name FROM orders o JOIN products p ON p.id=o.product_id ORDER BY o.created_at DESC LIMIT 100").fetchall()
    return render_template("admin.html",products=products,orders=orders,settings=settings())

@app.post("/admin/product/save")
@admin_required
def product_save():
    verify_csrf(); pid=request.form.get("id"); name=request.form.get("name","").strip(); desc=request.form.get("description","").strip()
    try: price=round(float(request.form.get("price","0"))*100)
    except ValueError: abort(400)
    if not name or price<0: abort(400)
    vals=(name,desc,price,request.form.get("category","数字商品")[:40],1 if request.form.get("active") else 0,int(request.form.get("sort_order","0") or 0))
    if pid: db().execute("UPDATE products SET name=?,description=?,price_cents=?,category=?,active=?,sort_order=? WHERE id=?",vals+(pid,))
    else: db().execute("INSERT INTO products(name,description,price_cents,category,active,sort_order,created_at) VALUES(?,?,?,?,?,?,?)",vals+(now(),))
    flash("商品已保存"); return redirect(url_for("admin"))

@app.post("/admin/inventory")
@admin_required
def inventory_add():
    verify_csrf(); pid=int(request.form["product_id"]); lines=[x.strip() for x in request.form.get("items","").splitlines() if x.strip()]
    if len(lines)>5000: abort(400)
    db().executemany("INSERT INTO inventory(product_id,payload,created_at) VALUES(?,?,?)",[(pid,enc(x),now()) for x in lines])
    flash(f"已加密导入 {len(lines)} 条库存"); return redirect(url_for("admin"))

@app.post("/admin/order/fulfill")
@admin_required
def admin_fulfill():
    verify_csrf(); fulfill(request.form["order_id"],"ADMIN-"+secrets.token_hex(4)); flash("订单已确认并自动发货/标记缺货")
    return redirect(url_for("admin"))

@app.post("/admin/settings")
@admin_required
def admin_settings():
    verify_csrf()
    allowed=("site_title","site_subtitle","icon_text","contact","wechat_id","notice","alipay_qr","wechat_qr","support_qr","payment_mode","base_url")
    for k in allowed: db().execute("INSERT INTO settings VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",(k,request.form.get(k,"")[:1000]))
    flash("网站设置已保存"); return redirect(url_for("admin"))

@app.post("/admin/payment-qr")
@admin_required
def admin_payment_qr():
    verify_csrf(); changed=[]
    Image.MAX_IMAGE_PIXELS=20_000_000
    for kind,field in (("alipay","alipay_qr_file"),("wechat","wechat_qr_file"),("support","support_qr_file")):
        upload=request.files.get(field)
        if not upload or not upload.filename: continue
        raw=upload.read(4*1024*1024+1)
        if not raw or len(raw)>4*1024*1024: flash(f"{kind}二维码必须小于4MB"); continue
        try:
            image=Image.open(io.BytesIO(raw)); image.load()
            if getattr(image,"n_frames",1)!=1: raise ValueError("animated image")
            image=image.convert("RGB"); image.thumbnail((1600,1600),Image.Resampling.LANCZOS)
            if image.width<150 or image.height<150: raise ValueError("image too small")
            tmp=QR_DIR/f".{kind}.{secrets.token_hex(4)}.tmp"
            image.save(tmp,format="PNG",optimize=True); os.replace(tmp,QR_DIR/f"{kind}.png")
            db().execute("INSERT INTO settings VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",(f"{kind}_qr",f"/payment-assets/{kind}.png"))
            changed.append({"alipay":"支付宝","wechat":"微信支付","support":"客服微信"}[kind])
        except (UnidentifiedImageError,OSError,ValueError,Image.DecompressionBombError):
            flash(f"{kind}文件不是有效的单张PNG/JPG/WebP二维码图片")
    if changed: flash("、".join(changed)+"收款二维码已上传并启用")
    elif not any(f and f.filename for f in request.files.values()): flash("请选择二维码图片")
    return redirect(url_for("admin"))

@app.post("/admin/password")
@admin_required
def admin_password():
    verify_csrf(); password=request.form.get("password","")
    if len(password)<12: flash("新密码至少12位"); return redirect(url_for("admin"))
    db().execute("UPDATE admins SET password_hash=? WHERE username=?",(generate_password_hash(password,method="scrypt"),session["admin"]))
    session.clear(); return redirect(url_for("admin_login"))

@app.post("/admin/payment-settings")
@admin_required
def admin_payment_settings():
    verify_csrf()
    public=("payment_mode","base_url","alipay_app_id","wechat_appid","wechat_mchid","wechat_serial")
    secret=("alipay_private_key","alipay_public_key","wechat_private_key","wechat_platform_public_key","wechat_apiv3_key")
    for k in public:
        v=request.form.get(k,"").strip()
        db().execute("INSERT INTO settings VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",(k,v))
    for k in secret:
        v=request.form.get(k,"").strip()
        if v: db().execute("INSERT INTO secret_settings VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",(k,enc(v)))
    flash("支付配置已加密保存"); return redirect(url_for("admin"))

@app.post("/payment/alipay/notify")
def alipay_notify():
    cfg=payment_config(); form=request.form.to_dict()
    if not alipay_verify(cfg,form): return "failure",400
    oid=form.get("out_trade_no",""); row=db().execute("SELECT * FROM orders WHERE id=?",(oid,)).fetchone()
    if not row or form.get("trade_status") not in ("TRADE_SUCCESS","TRADE_FINISHED"): return "failure",400
    if abs(float(form.get("total_amount","-1"))*100-row["amount_cents"])>0.1 or form.get("app_id")!=cfg.get("alipay_app_id"): return "failure",400
    fulfill(oid,form.get("trade_no","")); return "success"

@app.post("/payment/wechat/notify")
def wechat_notify():
    cfg=payment_config(); raw=request.get_data(as_text=True)
    if not wechat_verify_header(cfg,request.headers,raw): return jsonify(code="FAIL",message="invalid signature"),401
    data=wechat_decrypt(cfg,request.get_json()["resource"]); oid=data.get("out_trade_no","")
    row=db().execute("SELECT * FROM orders WHERE id=?",(oid,)).fetchone()
    if not row or data.get("trade_state")!="SUCCESS" or data.get("amount",{}).get("total")!=row["amount_cents"]: return jsonify(code="FAIL",message="order mismatch"),400
    fulfill(oid,data.get("transaction_id","")); return jsonify(code="SUCCESS",message="成功")

@app.get("/payment/return/<oid>")
def payment_return(oid): return redirect(url_for("order",oid=oid,code=session.get(f"order_{oid}","")))

@app.get("/healthz")
def health(): return jsonify(ok=True,db=db().execute("SELECT 1").fetchone()[0])

@app.cli.command("init-db")
def cli_init(): init_db(); print("initialized")

if __name__=="__main__": init_db(); app.run("127.0.0.1",8088)

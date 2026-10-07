# -*- coding: utf-8 -*-
import os,json,sqlite3,datetime,re,base64,hmac
BASE=os.path.dirname(os.path.abspath(__file__)); DB=os.environ.get("VACATION_DB",os.path.join(BASE,"data","vacation.db")); YEAR=int(os.environ.get("VACATION_YEAR","2027")); TYPES=("О","Д","Б","У")
REF=json.load(open(os.path.join(BASE,"reference.json"),encoding="utf8")); DEPTS=REF["departments"]
class ApiError(Exception):
 def __init__(self,s,m,x=None):self.status=s;self.message=m;self.extra=x or {}
def now():return datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
def con():
 os.makedirs(os.path.dirname(DB),exist_ok=True);c=sqlite3.connect(DB,timeout=15);c.row_factory=sqlite3.Row;c.execute("PRAGMA foreign_keys=ON");c.execute("PRAGMA journal_mode=WAL");c.execute("PRAGMA busy_timeout=15000");return c
SCHEMA="""CREATE TABLE IF NOT EXISTS employees(id INTEGER PRIMARY KEY AUTOINCREMENT,dept TEXT NOT NULL,subunit TEXT NOT NULL DEFAULT '',fio TEXT NOT NULL,job TEXT NOT NULL DEFAULT '',grp TEXT NOT NULL DEFAULT '',version INTEGER NOT NULL DEFAULT 1,updated_at TEXT,updated_by TEXT);CREATE TABLE IF NOT EXISTS periods(id INTEGER PRIMARY KEY AUTOINCREMENT,employee_id INTEGER NOT NULL REFERENCES employees(id) ON DELETE CASCADE,start_date TEXT NOT NULL,end_date TEXT NOT NULL,type TEXT NOT NULL);CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT NOT NULL);CREATE TABLE IF NOT EXISTS audit(id INTEGER PRIMARY KEY AUTOINCREMENT,ts TEXT,user TEXT,action TEXT,employee_id INTEGER,details TEXT);"""
def init_db():
 c=con();c.executescript(SCHEMA);c.execute("INSERT OR IGNORE INTO settings VALUES('rev','1')");c.execute("INSERT OR IGNORE INTO settings VALUES('thresholds','{}')");c.commit()
 if c.execute("SELECT COUNT(*) FROM employees").fetchone()[0]==0 and os.environ.get("VACATION_SEED","1")!="0":
  for x in json.load(open(os.path.join(BASE,"seed_employees.json"),encoding="utf8")):insert(c,"seed",x)
  c.execute("UPDATE settings SET value='2' WHERE key='rev'");c.commit()
 c.close()
def rev(c):return int(c.execute("SELECT value FROM settings WHERE key='rev'").fetchone()[0])
def bump(c):c.execute("UPDATE settings SET value=CAST(value AS INTEGER)+1 WHERE key='rev'")
def audit(c,u,a,e,d):c.execute("INSERT INTO audit(ts,user,action,employee_id,details) VALUES(?,?,?,?,?)",(now(),u,a,e,d))
def clean_emp(b):
 if not isinstance(b,dict):raise ApiError(400,"Ожидался JSON")
 d=str(b.get("dept","")).strip();f=str(b.get("fio","")).strip()
 if d not in DEPTS:raise ApiError(400,"Неизвестное подразделение")
 if not f:raise ApiError(400,"ФИО обязательно")
 if len(f)>200:raise ApiError(400,"Слишком длинное ФИО")
 return d,str(b.get("subunit","")).strip()[:300],f,str(b.get("job","")).strip()[:300],str(b.get("group","")).strip()[:200] or "Прочий персонал"
def clean_periods(ps):
 if not isinstance(ps,list) or len(ps)>400:raise ApiError(400,"Некорректные периоды")
 a=[]
 for p in ps:
  if not isinstance(p,dict) or p.get("type") not in TYPES:raise ApiError(400,"Некорректный код отпуска")
  try:s=datetime.date.fromisoformat(p["start"]);e=datetime.date.fromisoformat(p["end"])
  except:raise ApiError(400,"Некорректная дата")
  if s.year!=YEAR or e.year!=YEAR or s>e:raise ApiError(400,"Период вне года")
  a.append((s.isoformat(),e.isoformat(),p["type"]))
 a.sort()
 for i in range(1,len(a)):
  if a[i][0]<=a[i-1][1]:raise ApiError(400,"Периоды пересекаются")
 return a
def insert(c,u,b,keep=False):
 d,s,f,j,g=clean_emp(b);ps=clean_periods(b.get("periods",[]));eid=b.get("id") if keep and isinstance(b.get("id"),int) else None
 q=c.execute("INSERT INTO employees(id,dept,subunit,fio,job,grp,version,updated_at,updated_by) VALUES(?,?,?,?,?,?,1,?,?)",(eid,d,s,f,j,g,now(),u));eid=q.lastrowid
 c.executemany("INSERT INTO periods(employee_id,start_date,end_date,type) VALUES(?,?,?,?)",[(eid,a,b,t)for a,b,t in ps]);return eid
def emps(c,id=None):
 q="SELECT * FROM employees"+(" WHERE id=?" if id else "")+" ORDER BY id";rs=c.execute(q,(id,)if id else()).fetchall();p={}
 for x in c.execute("SELECT employee_id,start_date,end_date,type FROM periods ORDER BY start_date"):
  p.setdefault(x["employee_id"],[]).append({"start":x["start_date"],"end":x["end_date"],"type":x["type"]})
 return [{"id":r["id"],"dept":r["dept"],"subunit":r["subunit"],"fio":r["fio"],"job":r["job"],"group":r["grp"],"version":r["version"],"periods":p.get(r["id"],[])}for r in rs]
def ths(c):return json.loads(c.execute("SELECT value FROM settings WHERE key='thresholds'").fetchone()[0])
def conflict(c,id):
 x=emps(c,id)
 if not x:raise ApiError(404,"Сотрудник не найден")
 raise ApiError(409,"Запись изменена другим пользователем",{"employee":x[0]})
def version(b):
 try:return int(b["version"])
 except:raise ApiError(400,"Не передана версия записи")
def dispatch(method,path,args,body,user):
 c=con()
 try:
  if method=="GET" and path=="/api/data":
   es=emps(c);return 200,{"year":YEAR,"departments":DEPTS,"deptLabels":REF["deptLabels"],"subunits":REF["subunits"],"relatedGroups":sorted(set(REF["groups"])|{e["group"]for e in es}),"employees":es,"thresholds":ths(c),"rev":rev(c),"user":user},{}
  if method=="GET" and path=="/api/rev":return 200,{"rev":rev(c)},{}
  if method=="POST" and path=="/api/employees":
   id=insert(c,user,body);audit(c,user,"create",id,body.get("fio",""));bump(c);c.commit();return 201,{"employee":emps(c,id)[0],"rev":rev(c)},{}
  m=re.match(r"^/api/employees/(\d+)$",path)
  if method=="PUT" and m:
   id=int(m.group(1));d,s,f,j,g=clean_emp(body);v=version(body);q=c.execute("UPDATE employees SET dept=?,subunit=?,fio=?,job=?,grp=?,version=version+1,updated_at=?,updated_by=? WHERE id=? AND version=?",(d,s,f,j,g,now(),user,id,v))
   if not q.rowcount:conflict(c,id)
   audit(c,user,"update",id,f);bump(c);c.commit();return 200,{"employee":emps(c,id)[0],"rev":rev(c)},{}
  m=re.match(r"^/api/employees/(\d+)/periods$",path)
  if method=="PUT" and m:
   id=int(m.group(1));v=version(body);ps=clean_periods(body.get("periods",[]));q=c.execute("UPDATE employees SET version=version+1,updated_at=?,updated_by=? WHERE id=? AND version=?",(now(),user,id,v))
   if not q.rowcount:conflict(c,id)
   c.execute("DELETE FROM periods WHERE employee_id=?",(id,));c.executemany("INSERT INTO periods(employee_id,start_date,end_date,type) VALUES(?,?,?,?)",[(id,a,b,t)for a,b,t in ps]);audit(c,user,"periods",id,"изменение");bump(c);c.commit();return 200,{"employee":emps(c,id)[0],"rev":rev(c)},{}
  if method=="DELETE" and m:
   id=int(m.group(1));q=c.execute("DELETE FROM employees WHERE id=?",(id,))
   if not q.rowcount:raise ApiError(404,"Сотрудник не найден")
   audit(c,user,"delete",id,"");bump(c);c.commit();return 200,{"deleted":id,"rev":rev(c)},{}
  if method=="PUT" and path=="/api/thresholds":
   g=str(body.get("group","")).strip();v=int(body.get("value",0));x=ths(c);x[g]=v;c.execute("UPDATE settings SET value=? WHERE key='thresholds'",(json.dumps(x,ensure_ascii=False),));bump(c);c.commit();return 200,{"thresholds":x,"rev":rev(c)},{}
  if method=="GET" and path=="/api/backup":return 200,{"employees":emps(c),"thresholds":ths(c)},{}
  return 404,{"error":"Не найдено"},{}
 except ApiError as e:c.rollback();o={"error":e.message};o.update(e.extra);return e.status,o,{}
 except Exception as e:c.rollback();return 500,{"error":"Ошибка сервера: %s"%e},{}
 finally:c.close()
def users(s):return dict(x.split(":",1)for x in(s or "").split(",")if":"in x)
def auth(h,u):
 if not u:return"anonymous"
 if not h or not h.startswith("Basic "):return None
 try:a,p=base64.b64decode(h[6:]).decode().split(":",1)
 except:return None
 return a if a in u and hmac.compare_digest(u[a],p) else None

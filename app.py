import os,json
from flask import Flask,request,Response,send_from_directory
import core
app=Flask(__name__,static_folder=None); app.config['MAX_CONTENT_LENGTH']=20*1024*1024
USERS=core.users(os.environ.get('VACATION_USERS','')); core.init_db()
@app.before_request
def auth():
 if request.path=='/healthz':return None
 u=core.auth(request.headers.get('Authorization'),USERS)
 if u is None:return Response('Требуется авторизация',401,{'WWW-Authenticate':'Basic realm="Vacation", charset="UTF-8"'})
 request.environ['vacation.user']=u
@app.after_request
def cache(r):r.headers['Cache-Control']='no-store';return r
@app.route('/healthz')
def health():return 'ok'
@app.route('/')
def index():return send_from_directory(os.path.join(core.BASE,'static'),'index.html')
@app.route('/api/<path:p>',methods=['GET','POST','PUT','DELETE'])
def api(p):
 b=request.get_json(silent=True) if request.method in ('POST','PUT') else None
 st,out,h=core.dispatch(request.method,'/api/'+p,request.args.to_dict(),b,request.environ['vacation.user'])
 r=Response(json.dumps(out,ensure_ascii=False),st,mimetype='application/json')
 for k,v in h.items():r.headers[k]=v
 return r
if __name__=='__main__':app.run(host='0.0.0.0',port=8000)

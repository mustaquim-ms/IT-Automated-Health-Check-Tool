# app.py
import os, json, datetime
from flask import Flask, request, jsonify, g, render_template, send_file, abort
from flask_cors import CORS
from sqlalchemy import create_engine, MetaData, Table, Column, Integer, String, Text, DateTime
from sqlalchemy.sql import select
from dotenv import load_dotenv

load_dotenv()
API_TOKEN = os.getenv("AGG_API_TOKEN", "changeme")  # set strong token in env
DB_PATH = os.getenv("AGG_DB_PATH", "sqlite:///reports.db")

app = Flask(__name__)
CORS(app)

# DB setup
engine = create_engine(DB_PATH, connect_args={"check_same_thread": False} if 'sqlite' in DB_PATH else {})
metadata = MetaData()
reports = Table('reports', metadata,
                Column('id', Integer, primary_key=True),
                Column('host', String(256), nullable=False),
                Column('ts', DateTime, nullable=False),
                Column('score', Integer, nullable=True),
                Column('raw_json', Text, nullable=False)
)
metadata.create_all(engine)

def require_auth():
    auth = request.headers.get('Authorization','')
    if not auth.startswith('Bearer '): return False
    token = auth.split(' ',1)[1].strip()
    return token == API_TOKEN

@app.route('/api/report', methods=['POST'])
def receive_report():
    if not require_auth(): return jsonify({"error":"Unauthorized"}), 401
    try:
        payload = request.get_json(force=True)
    except Exception as e:
        return jsonify({"error":"Invalid JSON","detail":str(e)}), 400

    host = payload.get('host') or payload.get('hostname') or 'unknown'
    ts = payload.get('timestamp') or datetime.datetime.utcnow().isoformat()
    try:
        ts_dt = datetime.datetime.fromisoformat(ts)
    except:
        ts_dt = datetime.datetime.utcnow()

    score = payload.get('score')
    with engine.connect() as conn:
        ins = reports.insert().values(host=host, ts=ts_dt, score=score, raw_json=json.dumps(payload))
        res = conn.execute(ins)
        conn.commit()

    return jsonify({"status":"ok","message":"Report stored","id":res.inserted_primary_key[0]})

@app.route('/api/reports', methods=['GET'])
def list_reports():
    limit = int(request.args.get('limit',20))
    offset = int(request.args.get('offset',0))
    with engine.connect() as conn:
        q = select([reports]).order_by(reports.c.ts.desc()).limit(limit).offset(offset)
        rows = conn.execute(q).fetchall()
        out = []
        for r in rows:
            out.append({"id":r.id,"host":r.host,"timestamp":r.ts.isoformat(),"score":r.score})
    return jsonify(out)

@app.route('/api/report/<int:id>', methods=['GET'])
def get_report(id):
    with engine.connect() as conn:
        q = select([reports]).where(reports.c.id==id)
        r = conn.execute(q).fetchone()
        if not r: abort(404)
        return jsonify({"id":r.id,"host":r.host,"timestamp":r.ts.isoformat(),"score":r.score,"payload": json.loads(r.raw_json)})

# simple dashboard
@app.route('/dashboard', methods=['GET'])
def dashboard():
    # compute simple metrics
    with engine.connect() as conn:
        q = select([reports]).order_by(reports.c.ts.desc()).limit(500)
        rows = conn.execute(q).fetchall()
        hosts = {}
        times = []
        scores = []
        for r in rows:
            hosts.setdefault(r.host,0)
            hosts[r.host]+=1
            times.append(r.ts.isoformat())
            scores.append(r.score or 0)
    return render_template('dashboard.html', hosts=hosts, times=times, scores=scores)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=int(os.getenv('PORT',5000)), debug=(os.getenv('FLASK_DEBUG','0')=='1'))

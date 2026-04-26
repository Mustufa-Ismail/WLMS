import psycopg2
import psycopg2.extras
from flask import current_app, g


def get_db():
    if 'db' not in g:
        g.db = psycopg2.connect(
            host=current_app.config['DB_HOST'],
            port=current_app.config['DB_PORT'],
            dbname=current_app.config['DB_NAME'],
            user=current_app.config['DB_USER'],
            password=current_app.config['DB_PASSWORD'],
            cursor_factory=psycopg2.extras.RealDictCursor
        )
    return g.db


def close_db(e=None):
    db = g.pop('db', None)
    if db is not None:
        db.close()


def query(sql, params=None, fetchone=False, fetchall=False, commit=False):
    db = get_db()
    cur = db.cursor()
    cur.execute(sql, params or ())
    result = None
    if fetchone:
        result = cur.fetchone()
    elif fetchall:
        result = cur.fetchall()
    if commit:
        db.commit()
    cur.close()
    return result
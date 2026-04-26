from flask import Blueprint, jsonify
from flask_jwt_extended import jwt_required
from app.utils.db import query

bp = Blueprint('inventory', __name__, url_prefix='/api/inventory')

@bp.get('/stock')
@jwt_required()
def get_stock():
    rows = query("SELECT * FROM vw_stock_status ORDER BY item_id", fetchall=True)
    return jsonify([dict(r) for r in rows]), 200

@bp.get('/low-stock')
@jwt_required()
def get_low_stock():
    rows = query("SELECT * FROM vw_low_stock_alerts", fetchall=True)
    return jsonify([dict(r) for r in rows]), 200

@bp.get('/dashboard')
@jwt_required()
def get_dashboard():
    row = query("SELECT * FROM vw_admin_dashboard", fetchone=True)
    return jsonify(dict(row)), 200
from flask import Blueprint, jsonify, request
from flask_jwt_extended import jwt_required, get_jwt_identity
from app.utils.db import query
from app.utils.auth_helper import role_required

bp = Blueprint('sales_orders', __name__, url_prefix='/api/sales-orders')


@bp.get('/')
@jwt_required()
def get_all_sos():
    rows = query("SELECT * FROM vw_sales_order_full ORDER BY so_id DESC", fetchall=True)
    return jsonify([dict(r) for r in rows]), 200

@bp.get('/<int:so_id>')
@jwt_required()
def get_so(so_id):
    rows = query(
        "SELECT * FROM vw_sales_order_full WHERE so_id = %s",
        (so_id,), fetchall=True
    )
    if not rows:
        return jsonify({"msg": "Sales Order not found"}), 404
    return jsonify([dict(r) for r in rows]), 200

@bp.post('/')
@role_required('Administrator', 'Logistics Staff')
def create_so():
    data        = request.get_json()
    customer_id = data.get('customer_id')
    created_by  = int(get_jwt_identity())

    if not customer_id:
        return jsonify({"msg": "customer_id is required"}), 400

    query("CALL sp_create_sales_order(%s, %s)", (customer_id, created_by), commit=True)
    so = query("SELECT MAX(so_id) AS so_id FROM sales_orders", fetchone=True)
    return jsonify({"msg": "Sales Order created", "so_id": so['so_id']}), 201


@bp.post('/<int:so_id>/lines')
@role_required('Administrator', 'Logistics Staff')
def add_so_line(so_id):
    data       = request.get_json()
    item_id    = data.get('item_id')
    qty        = data.get('quantity')
    unit_price = data.get('unit_price', 0)

    if not item_id or not qty:
        return jsonify({"msg": "item_id and quantity are required"}), 400

    try:
        query(
            "CALL sp_add_so_line(%s, %s, %s, %s)",
            (so_id, item_id, qty, unit_price),
            commit=True
        )
        return jsonify({"msg": "Line added to Sales Order"}), 201
    except Exception as e:
        return jsonify({"msg": str(e)}), 400

@bp.patch('/<int:so_id>/advance')
@role_required('Administrator', 'Warehouse Staff')
def advance_so(so_id):
    try:
        query("CALL sp_advance_so_status(%s)", (so_id,), commit=True)
        so = query("SELECT status FROM sales_orders WHERE so_id = %s", (so_id,), fetchone=True)
        return jsonify({"msg": f"SO {so_id} advanced", "new_status": so['status']}), 200
    except Exception as e:
        return jsonify({"msg": str(e)}), 400

@bp.patch('/<int:so_id>/cancel')
@role_required('Administrator')
def cancel_so(so_id):
    try:
        query("CALL sp_cancel_sales_order(%s)", (so_id,), commit=True)
        return jsonify({"msg": f"SO {so_id} cancelled. Reserved stock released."}), 200
    except Exception as e:
        return jsonify({"msg": str(e)}), 400
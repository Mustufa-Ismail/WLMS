from flask import Blueprint, jsonify, request
from flask_jwt_extended import jwt_required, get_jwt_identity
from app.utils.db import query
from app.utils.auth_helper import role_required

bp = Blueprint('purchase_orders', __name__, url_prefix='/api/purchase-orders')


@bp.get('/')
@jwt_required()
def get_all_pos():
    rows = query("SELECT * FROM vw_purchase_order_full ORDER BY po_id DESC", fetchall=True)
    return jsonify([dict(r) for r in rows]), 200


@bp.get('/<int:po_id>')
@jwt_required()
def get_po(po_id):
    rows = query(
        "SELECT * FROM vw_purchase_order_full WHERE po_id = %s",
        (po_id,), fetchall=True
    )
    if not rows:
        return jsonify({"msg": "Purchase Order not found"}), 404
    return jsonify([dict(r) for r in rows]), 200


@bp.post('/')
@role_required('Administrator', 'Warehouse Staff')
def create_po():
    data = request.get_json()
    supplier_id = data.get('supplier_id')
    created_by  = int(get_jwt_identity())

    if not supplier_id:
        return jsonify({"msg": "supplier_id is required"}), 400

    query(
        "CALL sp_create_purchase_order(%s, %s)",
        (supplier_id, created_by),
        commit=True
    )
    po = query("SELECT MAX(po_id) AS po_id FROM purchase_orders", fetchone=True)
    return jsonify({"msg": "Purchase Order created", "po_id": po['po_id']}), 201


@bp.post('/<int:po_id>/lines')
@role_required('Administrator', 'Warehouse Staff')
def add_po_line(po_id):
    data = request.get_json()
    item_id   = data.get('item_id')
    qty       = data.get('quantity')
    unit_cost = data.get('unit_cost', 0)

    if not item_id or not qty:
        return jsonify({"msg": "item_id and quantity are required"}), 400

    query(
        "CALL sp_add_po_line(%s, %s, %s, %s)",
        (po_id, item_id, qty, unit_cost),
        commit=True
    )
    return jsonify({"msg": "Line added to Purchase Order"}), 201


@bp.patch('/<int:po_id>/cancel')
@role_required('Administrator')
def cancel_po(po_id):
    try:
        query("CALL sp_cancel_purchase_order(%s)", (po_id,), commit=True)
        return jsonify({"msg": f"PO {po_id} cancelled"}), 200
    except Exception as e:
        return jsonify({"msg": str(e)}), 400
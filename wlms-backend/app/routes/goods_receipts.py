from flask import Blueprint, jsonify, request
from flask_jwt_extended import jwt_required, get_jwt_identity
from app.utils.db import query
from app.utils.auth_helper import role_required

bp = Blueprint('goods_receipts', __name__, url_prefix='/api/goods-receipts')


@bp.get('/')
@jwt_required()
def get_all_grns():
    rows = query("SELECT * FROM vw_grn_full ORDER BY grn_id DESC", fetchall=True)
    return jsonify([dict(r) for r in rows]), 200


@bp.get('/<int:grn_id>')
@jwt_required()
def get_grn(grn_id):
    rows = query(
        "SELECT * FROM vw_grn_full WHERE grn_id = %s",
        (grn_id,), fetchall=True
    )
    if not rows:
        return jsonify({"msg": "GRN not found"}), 404
    return jsonify([dict(r) for r in rows]), 200


@bp.post('/')
@role_required('Administrator', 'Warehouse Staff')
def create_grn():
    data        = request.get_json()
    po_id       = data.get('po_id')
    received_by = int(get_jwt_identity())

    if not po_id:
        return jsonify({"msg": "po_id is required"}), 400

    query("CALL sp_create_grn(%s, %s)", (po_id, received_by), commit=True)
    grn = query("SELECT MAX(grn_id) AS grn_id FROM goods_receipts", fetchone=True)
    return jsonify({"msg": "GRN created", "grn_id": grn['grn_id']}), 201


@bp.post('/<int:grn_id>/lines')
@role_required('Administrator', 'Warehouse Staff')
def add_grn_line(grn_id):
    data    = request.get_json()
    item_id = data.get('item_id')
    qty     = data.get('quantity')

    if not item_id or not qty:
        return jsonify({"msg": "item_id and quantity are required"}), 400

    query("CALL sp_add_grn_line(%s, %s, %s)", (grn_id, item_id, qty), commit=True)
    return jsonify({"msg": "Line added to GRN"}), 201


@bp.patch('/<int:grn_id>/confirm')
@role_required('Administrator', 'Warehouse Staff')
def confirm_grn(grn_id):
    try:
        query("CALL sp_confirm_grn(%s)", (grn_id,), commit=True)
        return jsonify({"msg": f"GRN {grn_id} confirmed. Stock updated."}), 200
    except Exception as e:
        return jsonify({"msg": str(e)}), 400
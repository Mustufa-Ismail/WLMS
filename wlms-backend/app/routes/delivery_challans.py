from flask import Blueprint, jsonify, request
from flask_jwt_extended import jwt_required, get_jwt_identity
from app.utils.db import query
from app.utils.auth_helper import role_required

bp = Blueprint('delivery_challans', __name__, url_prefix='/api/delivery-challans')


@bp.get('/')
@jwt_required()
def get_all_dcs():
    rows = query("SELECT * FROM vw_delivery_challan_full ORDER BY dc_id DESC", fetchall=True)
    return jsonify([dict(r) for r in rows]), 200


@bp.get('/<int:dc_id>')
@jwt_required()
def get_dc(dc_id):
    rows = query(
        "SELECT * FROM vw_delivery_challan_full WHERE dc_id = %s",
        (dc_id,), fetchall=True
    )
    if not rows:
        return jsonify({"msg": "Delivery Challan not found"}), 404
    return jsonify([dict(r) for r in rows]), 200

@bp.post('/')
@role_required('Administrator', 'Logistics Staff')
def create_dc():
    data       = request.get_json()
    so_id      = data.get('so_id')
    created_by = int(get_jwt_identity())
    driver     = data.get('driver_name', '')
    vehicle    = data.get('vehicle_number', '')

    if not so_id:
        return jsonify({"msg": "so_id is required"}), 400

    try:
        query(
            "CALL sp_create_dc(%s, %s, %s, %s)",
            (so_id, created_by, driver, vehicle),
            commit=True
        )
        dc = query("SELECT MAX(dc_id) AS dc_id FROM delivery_challans", fetchone=True)
        return jsonify({"msg": "Delivery Challan created", "dc_id": dc['dc_id']}), 201
    except Exception as e:
        return jsonify({"msg": str(e)}), 400


@bp.post('/<int:dc_id>/lines')
@role_required('Administrator', 'Logistics Staff')
def add_dc_line(dc_id):
    data    = request.get_json()
    item_id = data.get('item_id')
    qty     = data.get('quantity')

    if not item_id or not qty:
        return jsonify({"msg": "item_id and quantity are required"}), 400

    query("CALL sp_add_dc_line(%s, %s, %s)", (dc_id, item_id, qty), commit=True)
    return jsonify({"msg": "Line added to Delivery Challan"}), 201


@bp.patch('/<int:dc_id>/dispatch')
@role_required('Administrator', 'Logistics Staff')
def dispatch_dc(dc_id):
    try:
        query("CALL sp_dispatch_dc(%s)", (dc_id,), commit=True)
        return jsonify({"msg": f"DC {dc_id} dispatched"}), 200
    except Exception as e:
        return jsonify({"msg": str(e)}), 400


@bp.patch('/<int:dc_id>/deliver')
@role_required('Administrator', 'Logistics Staff')
def deliver_dc(dc_id):
    try:
        query("CALL sp_deliver_dc(%s)", (dc_id,), commit=True)
        return jsonify({"msg": f"DC {dc_id} marked as delivered"}), 200
    except Exception as e:
        return jsonify({"msg": str(e)}), 400
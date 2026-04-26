from flask import Blueprint, jsonify, request
from flask_jwt_extended import jwt_required
from app.utils.db import query
from app.utils.auth_helper import role_required

bp = Blueprint('suppliers', __name__, url_prefix='/api/suppliers')

@bp.get('/')
@jwt_required()
def get_all_suppliers():
    rows = query(
        "SELECT * FROM suppliers WHERE is_active = TRUE ORDER BY supplier_name",
        fetchall=True
    )
    return jsonify([dict(r) for r in rows]), 200


@bp.get('/<int:supplier_id>')
@jwt_required()
def get_supplier(supplier_id):
    row = query(
        "SELECT * FROM suppliers WHERE supplier_id = %s",
        (supplier_id,), fetchone=True
    )
    if not row:
        return jsonify({"msg": "Supplier not found"}), 404
    return jsonify(dict(row)), 200


@bp.post('/')
@role_required('Administrator')
def create_supplier():
    data = request.get_json()
    name = data.get('supplier_name')
    if not name:
        return jsonify({"msg": "supplier_name is required"}), 400

    row = query(
        "INSERT INTO suppliers (supplier_name, email, phone, address) "
        "VALUES (%s, %s, %s, %s) RETURNING supplier_id",
        (name, data.get('email'), data.get('phone'), data.get('address')),
        fetchone=True, commit=True
    )
    return jsonify({"msg": "Supplier created", "supplier_id": row['supplier_id']}), 201

@bp.put('/<int:supplier_id>')
@role_required('Administrator')
def update_supplier(supplier_id):
    data = request.get_json()
    query(
        "UPDATE suppliers SET supplier_name=%s, email=%s, phone=%s, address=%s "
        "WHERE supplier_id=%s",
        (data.get('supplier_name'), data.get('email'),
         data.get('phone'), data.get('address'), supplier_id),
        commit=True
    )
    return jsonify({"msg": "Supplier updated"}), 200

@bp.patch('/<int:supplier_id>/deactivate')
@role_required('Administrator')
def deactivate_supplier(supplier_id):
    query(
        "UPDATE suppliers SET is_active = FALSE WHERE supplier_id = %s",
        (supplier_id,), commit=True
    )
    return jsonify({"msg": "Supplier deactivated"}), 200
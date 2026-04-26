from flask import Blueprint, jsonify, request
from flask_jwt_extended import jwt_required
from app.utils.db import query
from app.utils.auth_helper import role_required

bp = Blueprint('customers', __name__, url_prefix='/api/customers')

@bp.get('/')
@jwt_required()
def get_all_customers():
    rows = query(
        "SELECT * FROM customers ORDER BY customer_name",
        fetchall=True
    )
    return jsonify([dict(r) for r in rows]), 200

@bp.get('/<int:customer_id>')
@jwt_required()
def get_customer(customer_id):
    row = query(
        "SELECT * FROM customers WHERE customer_id = %s",
        (customer_id,), fetchone=True
    )
    if not row:
        return jsonify({"msg": "Customer not found"}), 404
    return jsonify(dict(row)), 200

@bp.post('/')
@role_required('Administrator', 'Logistics Staff')
def create_customer():
    data = request.get_json()
    name = data.get('customer_name')
    if not name:
        return jsonify({"msg": "customer_name is required"}), 400

    row = query(
        "INSERT INTO customers (customer_name, phone, address) "
        "VALUES (%s, %s, %s) RETURNING customer_id",
        (name, data.get('phone'), data.get('address')),
        fetchone=True, commit=True
    )
    return jsonify({"msg": "Customer created", "customer_id": row['customer_id']}), 201

@bp.put('/<int:customer_id>')
@role_required('Administrator', 'Logistics Staff')
def update_customer(customer_id):
    data = request.get_json()
    query(
        "UPDATE customers SET customer_name=%s, phone=%s, address=%s "
        "WHERE customer_id=%s",
        (data.get('customer_name'), data.get('phone'),
         data.get('address'), customer_id),
        commit=True
    )
    return jsonify({"msg": "Customer updated"}), 200
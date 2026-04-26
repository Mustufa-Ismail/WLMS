from flask import Blueprint, jsonify, request
from flask_jwt_extended import jwt_required
from app.utils.db import query
from app.utils.auth_helper import role_required
import bcrypt

bp = Blueprint('users', __name__, url_prefix='/api/users')

@bp.get('/')
@role_required('Administrator')
def get_all_users():
    rows = query(
        "SELECT u.user_id, u.username, u.is_active, u.created_at, "
        "       array_agg(r.role_name) AS roles "
        "FROM users u "
        "LEFT JOIN user_roles ur ON ur.user_id = u.user_id "
        "LEFT JOIN roles r ON r.role_id = ur.role_id "
        "GROUP BY u.user_id ORDER BY u.username",
        fetchall=True
    )
    return jsonify([dict(r) for r in rows]), 200

@bp.get('/<int:user_id>')
@role_required('Administrator')
def get_user(user_id):
    row = query(
        "SELECT u.user_id, u.username, u.is_active, u.created_at, "
        "       array_agg(r.role_name) AS roles "
        "FROM users u "
        "LEFT JOIN user_roles ur ON ur.user_id = u.user_id "
        "LEFT JOIN roles r ON r.role_id = ur.role_id "
        "WHERE u.user_id = %s "
        "GROUP BY u.user_id",
        (user_id,), fetchone=True
    )
    if not row:
        return jsonify({"msg": "User not found"}), 404
    return jsonify(dict(row)), 200

@bp.post('/')
@role_required('Administrator')
def create_user():
    data     = request.get_json()
    username = data.get('username')
    password = data.get('password')
    role     = data.get('role')  # 'Administrator' | 'Warehouse Staff' | 'Logistics Staff'

    if not username or not password or not role:
        return jsonify({"msg": "username, password and role are required"}), 400

    pw_hash = bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()

    role_row = query(
        "SELECT role_id FROM roles WHERE role_name = %s",
        (role,), fetchone=True
    )
    if not role_row:
        return jsonify({"msg": f"Role '{role}' does not exist"}), 400

    user_row = query(
        "INSERT INTO users (username, password_hash) VALUES (%s, %s) RETURNING user_id",
        (username, pw_hash), fetchone=True, commit=True
    )

    query(
        "INSERT INTO user_roles (user_id, role_id) VALUES (%s, %s)",
        (user_row['user_id'], role_row['role_id']), commit=True
    )

    return jsonify({"msg": "User created", "user_id": user_row['user_id']}), 201

@bp.patch('/<int:user_id>/deactivate')
@role_required('Administrator')
def deactivate_user(user_id):
    query(
        "UPDATE users SET is_active = FALSE WHERE user_id = %s",
        (user_id,), commit=True
    )
    return jsonify({"msg": "User deactivated"}), 200

@bp.patch('/<int:user_id>/change-password')
@role_required('Administrator')
def change_password(user_id):
    data     = request.get_json()
    password = data.get('password')
    if not password:
        return jsonify({"msg": "password is required"}), 400

    pw_hash = bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()
    query(
        "UPDATE users SET password_hash = %s WHERE user_id = %s",
        (pw_hash, user_id), commit=True
    )
    return jsonify({"msg": "Password updated"}), 200
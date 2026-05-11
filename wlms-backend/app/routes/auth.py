from flask import Blueprint, jsonify, request
from flask_jwt_extended import create_access_token, jwt_required, get_jwt_identity, get_jwt
from app.utils.db import query
import bcrypt

bp = Blueprint('auth', __name__, url_prefix='/api/auth')


@bp.post('/login')
def login():
    data = request.get_json()

    if not data or not data.get('username') or not data.get('password'):
        return jsonify({"msg": "Username and password required"}), 400

    user = query(
        "SELECT u.user_id, u.username, u.password_hash, u.is_active, r.role_name "
        "FROM users u "
        "JOIN user_roles ur ON ur.user_id = u.user_id "
        "JOIN roles r ON r.role_id = ur.role_id "
        "WHERE u.username = %s "
        "LIMIT 1",
        (data['username'],),
        fetchone=True
    )

    if not user:
        return jsonify({"msg": "Invalid username or password"}), 401

    if not user['is_active']:
        return jsonify({"msg": "Account is inactive"}), 403

    pw = data['password'].encode()
    stored = user['password_hash']
    try:
        valid = bcrypt.checkpw(pw, stored.encode())
    except Exception:
        valid = (stored == data['password'])

    if not valid:
        return jsonify({"msg": "Invalid username or password"}), 401

    token = create_access_token(
        identity=str(user['user_id']),
        additional_claims={"role": user['role_name']}
    )

    return jsonify({
        "access_token": token,
        "role":         user['role_name'],
        "username":     user['username']
    }), 200


@bp.get('/me')
@jwt_required()
def me():
    user_id = get_jwt_identity()
    claims  = get_jwt()
    return jsonify({
        "user_id": user_id,
        "role":    claims.get('role')
    }), 200


@bp.post('/logout')
@jwt_required()
def logout():
    return jsonify({"msg": "Logged out successfully"}), 200
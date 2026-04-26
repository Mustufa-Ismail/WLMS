from flask import Blueprint, jsonify, request
from flask_jwt_extended import jwt_required
from app.utils.db import query
from app.utils.auth_helper import role_required

bp = Blueprint('items', __name__, url_prefix='/api/items')

@bp.get('/')
@jwt_required()
def get_all_items():
    rows = query(
        "SELECT i.*, u.uom_name, u.uom_symbol "
        "FROM items i JOIN unit_of_measure u ON u.uom_id = i.uom_id "
        "WHERE i.is_active = TRUE ORDER BY i.item_name",
        fetchall=True
    )
    return jsonify([dict(r) for r in rows]), 200

@bp.get('/<int:item_id>')
@jwt_required()
def get_item(item_id):
    row = query(
        "SELECT i.*, u.uom_name, u.uom_symbol "
        "FROM items i JOIN unit_of_measure u ON u.uom_id = i.uom_id "
        "WHERE i.item_id = %s",
        (item_id,), fetchone=True
    )
    if not row:
        return jsonify({"msg": "Item not found"}), 404
    return jsonify(dict(row)), 200

@bp.post('/')
@role_required('Administrator', 'Warehouse Staff')
def create_item():
    data = request.get_json()
    name   = data.get('item_name')
    uom_id = data.get('uom_id')

    if not name or not uom_id:
        return jsonify({"msg": "item_name and uom_id are required"}), 400

    row = query(
        "INSERT INTO items (item_name, description, reorder_level, uom_id) "
        "VALUES (%s, %s, %s, %s) RETURNING item_id",
        (name, data.get('description'), data.get('reorder_level', 0), uom_id),
        fetchone=True, commit=True
    )
    return jsonify({"msg": "Item created", "item_id": row['item_id']}), 201

@bp.put('/<int:item_id>')
@role_required('Administrator', 'Warehouse Staff')
def update_item(item_id):
    data = request.get_json()
    query(
        "UPDATE items SET item_name=%s, description=%s, reorder_level=%s, uom_id=%s "
        "WHERE item_id=%s",
        (data.get('item_name'), data.get('description'),
         data.get('reorder_level', 0), data.get('uom_id'), item_id),
        commit=True
    )
    return jsonify({"msg": "Item updated"}), 200

@bp.patch('/<int:item_id>/deactivate')
@role_required('Administrator')
def deactivate_item(item_id):
    query(
        "UPDATE items SET is_active = FALSE WHERE item_id = %s",
        (item_id,), commit=True
    )
    return jsonify({"msg": "Item deactivated"}), 200

@bp.get('/uom')
@jwt_required()
def get_uom():
    rows = query("SELECT * FROM unit_of_measure ORDER BY uom_name", fetchall=True)
    return jsonify([dict(r) for r in rows]), 200
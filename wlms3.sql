--
-- PostgreSQL database dump
--

\restrict zZDShmrAMfqkSJaCyCOaKUp0NvPQmbeFCi2x1Cfi7XO1cTehJ4qUcV6zFGKZMYv

-- Dumped from database version 16.13
-- Dumped by pg_dump version 16.13

-- Started on 2026-04-25 15:18:56

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- TOC entry 278 (class 1255 OID 17261)
-- Name: fn_dc_delivered(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_dc_delivered() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_all_complete BOOLEAN;
BEGIN
    IF NEW.status = 'Delivered' AND OLD.status <> 'Delivered' THEN

        UPDATE delivery_challans
        SET delivered_at = NOW()
        WHERE dc_id = NEW.dc_id;

        SELECT bool_and(pending_quantity = 0)
        INTO v_all_complete
        FROM sales_order_lines
        WHERE so_id = NEW.so_id;

        IF v_all_complete THEN
            UPDATE sales_orders
            SET status = 'Delivered'
            WHERE so_id = NEW.so_id;
        END IF;

    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_dc_delivered() OWNER TO postgres;

--
-- TOC entry 277 (class 1255 OID 17259)
-- Name: fn_dc_dispatched(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_dc_dispatched() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_line         RECORD;
    v_ordered      NUMERIC(12,2);
    v_shipped      NUMERIC(12,2);
    v_all_complete BOOLEAN;
    v_new_status   VARCHAR(30);
BEGIN
    IF NEW.status = 'Dispatched' AND OLD.status <> 'Dispatched' THEN

        FOR v_line IN
            SELECT item_id, shipped_quantity
            FROM delivery_challan_lines
            WHERE dc_id = NEW.dc_id
        LOOP
            SELECT sol.ordered_quantity, sol.shipped_quantity
            INTO v_ordered, v_shipped
            FROM sales_order_lines sol
            JOIN delivery_challans dc ON dc.so_id = sol.so_id
            WHERE dc.dc_id = NEW.dc_id
              AND sol.item_id = v_line.item_id
            FOR UPDATE;

            IF v_shipped + v_line.shipped_quantity > v_ordered THEN
                RAISE EXCEPTION
                    'Shipment exceeds Sales Order quantity for item_id %', v_line.item_id;
            END IF;

            UPDATE stock_balance
            SET reserved_quantity = reserved_quantity - v_line.shipped_quantity
            WHERE item_id = v_line.item_id;

            UPDATE sales_order_lines
            SET shipped_quantity = shipped_quantity + v_line.shipped_quantity
            FROM delivery_challans dc
            WHERE dc.dc_id = NEW.dc_id
              AND sales_order_lines.so_id = dc.so_id
              AND sales_order_lines.item_id = v_line.item_id;
        END LOOP;

        SELECT bool_and(pending_quantity = 0)
        INTO v_all_complete
        FROM sales_order_lines
        WHERE so_id = NEW.so_id;

        v_new_status := CASE WHEN v_all_complete THEN 'Shipped' ELSE 'Processing' END;

        UPDATE sales_orders
        SET status = v_new_status
        WHERE so_id = NEW.so_id;

        UPDATE delivery_challans
        SET dispatched_at = NOW()
        WHERE dc_id = NEW.dc_id;

    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_dc_dispatched() OWNER TO postgres;

--
-- TOC entry 275 (class 1255 OID 17255)
-- Name: fn_grn_confirm_stock(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_grn_confirm_stock() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_line         RECORD;
    v_ordered      NUMERIC(12,2);
    v_received     NUMERIC(12,2);
    v_all_complete BOOLEAN;
    v_new_status   VARCHAR(30);
BEGIN
    IF NEW.status = 'Confirmed' AND OLD.status <> 'Confirmed' THEN

        FOR v_line IN
            SELECT item_id, received_quantity
            FROM goods_receipt_lines
            WHERE grn_id = NEW.grn_id
        LOOP
            SELECT ordered_quantity, received_quantity
            INTO v_ordered, v_received
            FROM purchase_order_lines
            WHERE po_id = NEW.po_id
              AND item_id = v_line.item_id
            FOR UPDATE;

            IF v_received + v_line.received_quantity > v_ordered THEN
                RAISE EXCEPTION
                    'GRN exceeds PO quantity for item_id %', v_line.item_id;
            END IF;

            UPDATE stock_balance
            SET available_quantity = available_quantity + v_line.received_quantity
            WHERE item_id = v_line.item_id;

            UPDATE purchase_order_lines
            SET received_quantity = received_quantity + v_line.received_quantity
            WHERE po_id = NEW.po_id
              AND item_id = v_line.item_id;
        END LOOP;

        SELECT bool_and(pending_quantity = 0)
        INTO v_all_complete
        FROM purchase_order_lines
        WHERE po_id = NEW.po_id;

        IF v_all_complete THEN
            v_new_status := 'Completed';
        ELSE
            v_new_status := 'Partially_Received';
        END IF;

        UPDATE purchase_orders
        SET status     = v_new_status,
            received_at = CASE WHEN v_new_status = 'Completed' THEN NOW() ELSE received_at END
        WHERE po_id = NEW.po_id;

    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_grn_confirm_stock() OWNER TO postgres;

--
-- TOC entry 254 (class 1255 OID 17253)
-- Name: fn_init_stock_balance(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_init_stock_balance() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO stock_balance (item_id, available_quantity, reserved_quantity)
    VALUES (NEW.item_id, 0, 0)
    ON CONFLICT (item_id) DO NOTHING;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_init_stock_balance() OWNER TO postgres;

--
-- TOC entry 276 (class 1255 OID 17257)
-- Name: fn_so_line_reserve_stock(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_so_line_reserve_stock() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_available NUMERIC(12,2);
BEGIN
    SELECT available_quantity
    INTO   v_available
    FROM   stock_balance
    WHERE  item_id = NEW.item_id
    FOR UPDATE;

    IF v_available < NEW.ordered_quantity THEN
        RAISE EXCEPTION
            'Insufficient stock for item_id %. Available: %, Requested: %',
            NEW.item_id, v_available, NEW.ordered_quantity;
    END IF;

    UPDATE stock_balance
    SET    available_quantity = available_quantity - NEW.ordered_quantity,
           reserved_quantity  = reserved_quantity  + NEW.ordered_quantity
    WHERE  item_id = NEW.item_id;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_so_line_reserve_stock() OWNER TO postgres;

--
-- TOC entry 280 (class 1255 OID 17266)
-- Name: fn_stamp_stock_last_updated(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_stamp_stock_last_updated() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.last_updated := NOW();
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_stamp_stock_last_updated() OWNER TO postgres;

--
-- TOC entry 279 (class 1255 OID 17263)
-- Name: fn_stamp_updated_at(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_stamp_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_stamp_updated_at() OWNER TO postgres;

--
-- TOC entry 260 (class 1255 OID 17310)
-- Name: sp_add_dc_line(integer, integer, numeric); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.sp_add_dc_line(IN p_dc_id integer, IN p_item_id integer, IN p_qty numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO delivery_challan_lines (dc_id, item_id, shipped_quantity)
    VALUES (p_dc_id, p_item_id, p_qty);
END;
$$;


ALTER PROCEDURE public.sp_add_dc_line(IN p_dc_id integer, IN p_item_id integer, IN p_qty numeric) OWNER TO postgres;

--
-- TOC entry 255 (class 1255 OID 17305)
-- Name: sp_add_grn_line(integer, integer, numeric); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.sp_add_grn_line(IN p_grn_id integer, IN p_item_id integer, IN p_qty numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO goods_receipt_lines (grn_id, item_id, received_quantity)
    VALUES (p_grn_id, p_item_id, p_qty);
END;
$$;


ALTER PROCEDURE public.sp_add_grn_line(IN p_grn_id integer, IN p_item_id integer, IN p_qty numeric) OWNER TO postgres;

--
-- TOC entry 282 (class 1255 OID 17303)
-- Name: sp_add_po_line(integer, integer, numeric, numeric); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.sp_add_po_line(IN p_po_id integer, IN p_item_id integer, IN p_qty numeric, IN p_unit_cost numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO purchase_order_lines (po_id, item_id, ordered_quantity, unit_cost)
    VALUES (p_po_id, p_item_id, p_qty, p_unit_cost);
END;
$$;


ALTER PROCEDURE public.sp_add_po_line(IN p_po_id integer, IN p_item_id integer, IN p_qty numeric, IN p_unit_cost numeric) OWNER TO postgres;

--
-- TOC entry 258 (class 1255 OID 17308)
-- Name: sp_add_so_line(integer, integer, numeric, numeric); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.sp_add_so_line(IN p_so_id integer, IN p_item_id integer, IN p_qty numeric, IN p_unit_price numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO sales_order_lines (so_id, item_id, ordered_quantity, unit_price)
    VALUES (p_so_id, p_item_id, p_qty, p_unit_price);
END;
$$;


ALTER PROCEDURE public.sp_add_so_line(IN p_so_id integer, IN p_item_id integer, IN p_qty numeric, IN p_unit_price numeric) OWNER TO postgres;

--
-- TOC entry 263 (class 1255 OID 17313)
-- Name: sp_advance_so_status(integer); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.sp_advance_so_status(IN p_so_id integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_current VARCHAR(30);
    v_next    VARCHAR(30);
BEGIN
    SELECT status INTO v_current
    FROM   sales_orders
    WHERE  so_id = p_so_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sales Order % not found.', p_so_id;
    END IF;

    v_next := CASE v_current
        WHEN 'Pending'    THEN 'Processing'
        WHEN 'Processing' THEN 'Packed'
        ELSE NULL
    END;

    IF v_next IS NULL THEN
        RAISE EXCEPTION
            'SO % cannot be advanced from status "%". Only Pending and Processing can be manually advanced.',
            p_so_id, v_current;
    END IF;

    UPDATE sales_orders
    SET    status = v_next
    WHERE  so_id  = p_so_id;

    RAISE NOTICE 'SO % moved from % → %.', p_so_id, v_current, v_next;
END;
$$;


ALTER PROCEDURE public.sp_advance_so_status(IN p_so_id integer) OWNER TO postgres;

--
-- TOC entry 285 (class 1255 OID 17315)
-- Name: sp_cancel_purchase_order(integer); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.sp_cancel_purchase_order(IN p_po_id integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_status VARCHAR(30);
BEGIN
    SELECT status INTO v_status
    FROM   purchase_orders
    WHERE  po_id = p_po_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Purchase Order % not found.', p_po_id;
    END IF;

    IF v_status <> 'Pending' THEN
        RAISE EXCEPTION
            'PO % cannot be cancelled. Only Pending POs can be cancelled. Current status: %.',
            p_po_id, v_status;
    END IF;

    UPDATE purchase_orders
    SET    status = 'Cancelled'
    WHERE  po_id  = p_po_id;

    RAISE NOTICE 'PO % cancelled.', p_po_id;
END;
$$;


ALTER PROCEDURE public.sp_cancel_purchase_order(IN p_po_id integer) OWNER TO postgres;

--
-- TOC entry 284 (class 1255 OID 17314)
-- Name: sp_cancel_sales_order(integer); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.sp_cancel_sales_order(IN p_so_id integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_status VARCHAR(30);
    v_line   RECORD;
BEGIN
    SELECT status INTO v_status
    FROM   sales_orders
    WHERE  so_id = p_so_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sales Order % not found.', p_so_id;
    END IF;

    IF v_status IN ('Shipped', 'Delivered', 'Cancelled') THEN
        RAISE EXCEPTION
            'SO % cannot be cancelled. Current status: %.', p_so_id, v_status;
    END IF;

    FOR v_line IN
        SELECT item_id,
               ordered_quantity - shipped_quantity AS qty_to_release
        FROM   sales_order_lines
        WHERE  so_id = p_so_id
        AND    (ordered_quantity - shipped_quantity) > 0
    LOOP
        UPDATE stock_balance
        SET    available_quantity = available_quantity + v_line.qty_to_release,
               reserved_quantity  = reserved_quantity  - v_line.qty_to_release
        WHERE  item_id = v_line.item_id;
    END LOOP;

    UPDATE sales_orders
    SET    status = 'Cancelled'
    WHERE  so_id  = p_so_id;

    RAISE NOTICE 'SO % cancelled. Reserved stock released.', p_so_id;
END;
$$;


ALTER PROCEDURE public.sp_cancel_sales_order(IN p_so_id integer) OWNER TO postgres;

--
-- TOC entry 256 (class 1255 OID 17306)
-- Name: sp_confirm_grn(integer); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.sp_confirm_grn(IN p_grn_id integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE goods_receipts
    SET status = 'Confirmed'
    WHERE grn_id = p_grn_id;
END;
$$;


ALTER PROCEDURE public.sp_confirm_grn(IN p_grn_id integer) OWNER TO postgres;

--
-- TOC entry 259 (class 1255 OID 17309)
-- Name: sp_create_dc(integer, integer, character varying, character varying); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.sp_create_dc(IN p_so_id integer, IN p_created_by integer, IN p_driver character varying, IN p_vehicle character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_status VARCHAR(30);
BEGIN
    SELECT status INTO v_status
    FROM   sales_orders
    WHERE  so_id = p_so_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sales Order % not found.', p_so_id;
    END IF;

    IF v_status <> 'Packed' THEN
        RAISE EXCEPTION
            'SO % must be Packed before creating a DC. Current status: %.',
            p_so_id, v_status;
    END IF;

    INSERT INTO delivery_challans (so_id, created_by, driver_name, vehicle_number)
    VALUES (p_so_id, p_created_by, p_driver, p_vehicle);
END;
$$;


ALTER PROCEDURE public.sp_create_dc(IN p_so_id integer, IN p_created_by integer, IN p_driver character varying, IN p_vehicle character varying) OWNER TO postgres;

--
-- TOC entry 283 (class 1255 OID 17304)
-- Name: sp_create_grn(integer, integer); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.sp_create_grn(IN p_po_id integer, IN p_received_by integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO goods_receipts (po_id, received_by, status)
    VALUES (p_po_id, p_received_by, 'Draft');
END;
$$;


ALTER PROCEDURE public.sp_create_grn(IN p_po_id integer, IN p_received_by integer) OWNER TO postgres;

--
-- TOC entry 281 (class 1255 OID 17302)
-- Name: sp_create_purchase_order(integer, integer); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.sp_create_purchase_order(IN p_supplier_id integer, IN p_created_by integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO purchase_orders (supplier_id, created_by)
    VALUES (p_supplier_id, p_created_by);
END;
$$;


ALTER PROCEDURE public.sp_create_purchase_order(IN p_supplier_id integer, IN p_created_by integer) OWNER TO postgres;

--
-- TOC entry 257 (class 1255 OID 17307)
-- Name: sp_create_sales_order(integer, integer); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.sp_create_sales_order(IN p_customer_id integer, IN p_created_by integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO sales_orders (customer_id, created_by)
    VALUES (p_customer_id, p_created_by);
END;
$$;


ALTER PROCEDURE public.sp_create_sales_order(IN p_customer_id integer, IN p_created_by integer) OWNER TO postgres;

--
-- TOC entry 262 (class 1255 OID 17312)
-- Name: sp_deliver_dc(integer); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.sp_deliver_dc(IN p_dc_id integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE delivery_challans
    SET status = 'Delivered'
    WHERE dc_id = p_dc_id;
END;
$$;


ALTER PROCEDURE public.sp_deliver_dc(IN p_dc_id integer) OWNER TO postgres;

--
-- TOC entry 261 (class 1255 OID 17311)
-- Name: sp_dispatch_dc(integer); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.sp_dispatch_dc(IN p_dc_id integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE delivery_challans
    SET status = 'Dispatched'
    WHERE dc_id = p_dc_id;
END;
$$;


ALTER PROCEDURE public.sp_dispatch_dc(IN p_dc_id integer) OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- TOC entry 227 (class 1259 OID 17028)
-- Name: customers; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.customers (
    customer_id integer NOT NULL,
    customer_name character varying(150) NOT NULL,
    phone character varying(30),
    address text,
    created_at timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.customers OWNER TO postgres;

--
-- TOC entry 226 (class 1259 OID 17027)
-- Name: customers_customer_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.customers_customer_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.customers_customer_id_seq OWNER TO postgres;

--
-- TOC entry 5186 (class 0 OID 0)
-- Dependencies: 226
-- Name: customers_customer_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.customers_customer_id_seq OWNED BY public.customers.customer_id;


--
-- TOC entry 246 (class 1259 OID 17233)
-- Name: delivery_challan_lines; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.delivery_challan_lines (
    dc_line_id integer NOT NULL,
    dc_id integer NOT NULL,
    item_id integer NOT NULL,
    shipped_quantity numeric(12,2) NOT NULL,
    CONSTRAINT delivery_challan_lines_shipped_quantity_check CHECK ((shipped_quantity > (0)::numeric))
);


ALTER TABLE public.delivery_challan_lines OWNER TO postgres;

--
-- TOC entry 245 (class 1259 OID 17232)
-- Name: delivery_challan_lines_dc_line_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.delivery_challan_lines_dc_line_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.delivery_challan_lines_dc_line_id_seq OWNER TO postgres;

--
-- TOC entry 5187 (class 0 OID 0)
-- Dependencies: 245
-- Name: delivery_challan_lines_dc_line_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.delivery_challan_lines_dc_line_id_seq OWNED BY public.delivery_challan_lines.dc_line_id;


--
-- TOC entry 244 (class 1259 OID 17211)
-- Name: delivery_challans; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.delivery_challans (
    dc_id integer NOT NULL,
    so_id integer NOT NULL,
    created_by integer NOT NULL,
    driver_name character varying(150),
    vehicle_number character varying(50),
    status character varying(30) DEFAULT 'Pending'::character varying NOT NULL,
    notes text,
    dispatched_at timestamp without time zone,
    delivered_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT delivery_challans_status_check CHECK (((status)::text = ANY ((ARRAY['Pending'::character varying, 'Dispatched'::character varying, 'Delivered'::character varying, 'Failed'::character varying])::text[])))
);


ALTER TABLE public.delivery_challans OWNER TO postgres;

--
-- TOC entry 243 (class 1259 OID 17210)
-- Name: delivery_challans_dc_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.delivery_challans_dc_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.delivery_challans_dc_id_seq OWNER TO postgres;

--
-- TOC entry 5188 (class 0 OID 0)
-- Dependencies: 243
-- Name: delivery_challans_dc_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.delivery_challans_dc_id_seq OWNED BY public.delivery_challans.dc_id;


--
-- TOC entry 221 (class 1259 OID 16997)
-- Name: document_types; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.document_types (
    document_type_id integer NOT NULL,
    document_name character varying(100) NOT NULL,
    description text
);


ALTER TABLE public.document_types OWNER TO postgres;

--
-- TOC entry 220 (class 1259 OID 16996)
-- Name: document_types_document_type_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.document_types_document_type_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.document_types_document_type_id_seq OWNER TO postgres;

--
-- TOC entry 5189 (class 0 OID 0)
-- Dependencies: 220
-- Name: document_types_document_type_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.document_types_document_type_id_seq OWNED BY public.document_types.document_type_id;


--
-- TOC entry 238 (class 1259 OID 17141)
-- Name: goods_receipt_lines; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.goods_receipt_lines (
    grn_line_id integer NOT NULL,
    grn_id integer NOT NULL,
    item_id integer NOT NULL,
    received_quantity numeric(12,2) NOT NULL,
    CONSTRAINT goods_receipt_lines_received_quantity_check CHECK ((received_quantity > (0)::numeric))
);


ALTER TABLE public.goods_receipt_lines OWNER TO postgres;

--
-- TOC entry 237 (class 1259 OID 17140)
-- Name: goods_receipt_lines_grn_line_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.goods_receipt_lines_grn_line_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.goods_receipt_lines_grn_line_id_seq OWNER TO postgres;

--
-- TOC entry 5190 (class 0 OID 0)
-- Dependencies: 237
-- Name: goods_receipt_lines_grn_line_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.goods_receipt_lines_grn_line_id_seq OWNED BY public.goods_receipt_lines.grn_line_id;


--
-- TOC entry 236 (class 1259 OID 17119)
-- Name: goods_receipts; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.goods_receipts (
    grn_id integer NOT NULL,
    po_id integer NOT NULL,
    received_by integer NOT NULL,
    status character varying(30) DEFAULT 'Draft'::character varying NOT NULL,
    notes text,
    received_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT goods_receipts_status_check CHECK (((status)::text = ANY ((ARRAY['Draft'::character varying, 'Confirmed'::character varying])::text[])))
);


ALTER TABLE public.goods_receipts OWNER TO postgres;

--
-- TOC entry 235 (class 1259 OID 17118)
-- Name: goods_receipts_grn_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.goods_receipts_grn_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.goods_receipts_grn_id_seq OWNER TO postgres;

--
-- TOC entry 5191 (class 0 OID 0)
-- Dependencies: 235
-- Name: goods_receipts_grn_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.goods_receipts_grn_id_seq OWNED BY public.goods_receipts.grn_id;


--
-- TOC entry 229 (class 1259 OID 17038)
-- Name: items; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.items (
    item_id integer NOT NULL,
    item_name character varying(200) NOT NULL,
    description text,
    reorder_level numeric(12,2) DEFAULT 0 NOT NULL,
    uom_id integer NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT items_reorder_level_check CHECK ((reorder_level >= (0)::numeric))
);


ALTER TABLE public.items OWNER TO postgres;

--
-- TOC entry 228 (class 1259 OID 17037)
-- Name: items_item_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.items_item_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.items_item_id_seq OWNER TO postgres;

--
-- TOC entry 5192 (class 0 OID 0)
-- Dependencies: 228
-- Name: items_item_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.items_item_id_seq OWNED BY public.items.item_id;


--
-- TOC entry 234 (class 1259 OID 17094)
-- Name: purchase_order_lines; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.purchase_order_lines (
    po_line_id integer NOT NULL,
    po_id integer NOT NULL,
    item_id integer NOT NULL,
    ordered_quantity numeric(12,2) NOT NULL,
    received_quantity numeric(12,2) DEFAULT 0 NOT NULL,
    pending_quantity numeric(12,2) GENERATED ALWAYS AS ((ordered_quantity - received_quantity)) STORED,
    unit_cost numeric(12,2) DEFAULT 0 NOT NULL,
    line_total numeric(14,2) GENERATED ALWAYS AS ((ordered_quantity * unit_cost)) STORED,
    CONSTRAINT purchase_order_lines_ordered_quantity_check CHECK ((ordered_quantity > (0)::numeric)),
    CONSTRAINT purchase_order_lines_received_quantity_check CHECK ((received_quantity >= (0)::numeric))
);


ALTER TABLE public.purchase_order_lines OWNER TO postgres;

--
-- TOC entry 233 (class 1259 OID 17093)
-- Name: purchase_order_lines_po_line_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.purchase_order_lines_po_line_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.purchase_order_lines_po_line_id_seq OWNER TO postgres;

--
-- TOC entry 5193 (class 0 OID 0)
-- Dependencies: 233
-- Name: purchase_order_lines_po_line_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.purchase_order_lines_po_line_id_seq OWNED BY public.purchase_order_lines.po_line_id;


--
-- TOC entry 232 (class 1259 OID 17071)
-- Name: purchase_orders; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.purchase_orders (
    po_id integer NOT NULL,
    supplier_id integer NOT NULL,
    created_by integer NOT NULL,
    status character varying(30) DEFAULT 'Pending'::character varying NOT NULL,
    notes text,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    received_at timestamp without time zone,
    CONSTRAINT purchase_orders_status_check CHECK (((status)::text = ANY ((ARRAY['Pending'::character varying, 'Partially_Received'::character varying, 'Completed'::character varying, 'Cancelled'::character varying])::text[])))
);


ALTER TABLE public.purchase_orders OWNER TO postgres;

--
-- TOC entry 231 (class 1259 OID 17070)
-- Name: purchase_orders_po_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.purchase_orders_po_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.purchase_orders_po_id_seq OWNER TO postgres;

--
-- TOC entry 5194 (class 0 OID 0)
-- Dependencies: 231
-- Name: purchase_orders_po_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.purchase_orders_po_id_seq OWNED BY public.purchase_orders.po_id;


--
-- TOC entry 218 (class 1259 OID 16973)
-- Name: roles; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.roles (
    role_id integer NOT NULL,
    role_name character varying(50) NOT NULL
);


ALTER TABLE public.roles OWNER TO postgres;

--
-- TOC entry 217 (class 1259 OID 16972)
-- Name: roles_role_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.roles_role_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.roles_role_id_seq OWNER TO postgres;

--
-- TOC entry 5195 (class 0 OID 0)
-- Dependencies: 217
-- Name: roles_role_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.roles_role_id_seq OWNED BY public.roles.role_id;


--
-- TOC entry 242 (class 1259 OID 17186)
-- Name: sales_order_lines; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sales_order_lines (
    so_line_id integer NOT NULL,
    so_id integer NOT NULL,
    item_id integer NOT NULL,
    ordered_quantity numeric(12,2) NOT NULL,
    shipped_quantity numeric(12,2) DEFAULT 0 NOT NULL,
    pending_quantity numeric(12,2) GENERATED ALWAYS AS ((ordered_quantity - shipped_quantity)) STORED,
    unit_price numeric(12,2) DEFAULT 0 NOT NULL,
    line_total numeric(14,2) GENERATED ALWAYS AS ((ordered_quantity * unit_price)) STORED,
    CONSTRAINT sales_order_lines_ordered_quantity_check CHECK ((ordered_quantity > (0)::numeric)),
    CONSTRAINT sales_order_lines_shipped_quantity_check CHECK ((shipped_quantity >= (0)::numeric))
);


ALTER TABLE public.sales_order_lines OWNER TO postgres;

--
-- TOC entry 241 (class 1259 OID 17185)
-- Name: sales_order_lines_so_line_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.sales_order_lines_so_line_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.sales_order_lines_so_line_id_seq OWNER TO postgres;

--
-- TOC entry 5196 (class 0 OID 0)
-- Dependencies: 241
-- Name: sales_order_lines_so_line_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.sales_order_lines_so_line_id_seq OWNED BY public.sales_order_lines.so_line_id;


--
-- TOC entry 240 (class 1259 OID 17161)
-- Name: sales_orders; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sales_orders (
    so_id integer NOT NULL,
    customer_id integer NOT NULL,
    created_by integer NOT NULL,
    status character varying(30) DEFAULT 'Pending'::character varying NOT NULL,
    payment_status character varying(30) DEFAULT 'Unpaid'::character varying NOT NULL,
    notes text,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT sales_orders_payment_status_check CHECK (((payment_status)::text = ANY ((ARRAY['Unpaid'::character varying, 'Paid'::character varying, 'Partial'::character varying])::text[]))),
    CONSTRAINT sales_orders_status_check CHECK (((status)::text = ANY ((ARRAY['Pending'::character varying, 'Processing'::character varying, 'Packed'::character varying, 'Shipped'::character varying, 'Delivered'::character varying, 'Cancelled'::character varying])::text[])))
);


ALTER TABLE public.sales_orders OWNER TO postgres;

--
-- TOC entry 239 (class 1259 OID 17160)
-- Name: sales_orders_so_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.sales_orders_so_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.sales_orders_so_id_seq OWNER TO postgres;

--
-- TOC entry 5197 (class 0 OID 0)
-- Dependencies: 239
-- Name: sales_orders_so_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.sales_orders_so_id_seq OWNED BY public.sales_orders.so_id;


--
-- TOC entry 230 (class 1259 OID 17055)
-- Name: stock_balance; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.stock_balance (
    item_id integer NOT NULL,
    available_quantity numeric(12,2) DEFAULT 0 NOT NULL,
    reserved_quantity numeric(12,2) DEFAULT 0 NOT NULL,
    last_updated timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT stock_balance_available_quantity_check CHECK ((available_quantity >= (0)::numeric)),
    CONSTRAINT stock_balance_reserved_quantity_check CHECK ((reserved_quantity >= (0)::numeric))
);


ALTER TABLE public.stock_balance OWNER TO postgres;

--
-- TOC entry 225 (class 1259 OID 17017)
-- Name: suppliers; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.suppliers (
    supplier_id integer NOT NULL,
    supplier_name character varying(150) NOT NULL,
    email character varying(150),
    phone character varying(30),
    address text,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.suppliers OWNER TO postgres;

--
-- TOC entry 224 (class 1259 OID 17016)
-- Name: suppliers_supplier_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.suppliers_supplier_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.suppliers_supplier_id_seq OWNER TO postgres;

--
-- TOC entry 5198 (class 0 OID 0)
-- Dependencies: 224
-- Name: suppliers_supplier_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.suppliers_supplier_id_seq OWNED BY public.suppliers.supplier_id;


--
-- TOC entry 223 (class 1259 OID 17008)
-- Name: unit_of_measure; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.unit_of_measure (
    uom_id integer NOT NULL,
    uom_name character varying(50) NOT NULL,
    uom_symbol character varying(10) NOT NULL
);


ALTER TABLE public.unit_of_measure OWNER TO postgres;

--
-- TOC entry 222 (class 1259 OID 17007)
-- Name: unit_of_measure_uom_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.unit_of_measure_uom_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.unit_of_measure_uom_id_seq OWNER TO postgres;

--
-- TOC entry 5199 (class 0 OID 0)
-- Dependencies: 222
-- Name: unit_of_measure_uom_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.unit_of_measure_uom_id_seq OWNED BY public.unit_of_measure.uom_id;


--
-- TOC entry 219 (class 1259 OID 16981)
-- Name: user_roles; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.user_roles (
    user_id integer NOT NULL,
    role_id integer NOT NULL
);


ALTER TABLE public.user_roles OWNER TO postgres;

--
-- TOC entry 216 (class 1259 OID 16960)
-- Name: users; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.users (
    user_id integer NOT NULL,
    username character varying(100) NOT NULL,
    password_hash text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.users OWNER TO postgres;

--
-- TOC entry 215 (class 1259 OID 16959)
-- Name: users_user_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.users_user_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.users_user_id_seq OWNER TO postgres;

--
-- TOC entry 5200 (class 0 OID 0)
-- Dependencies: 215
-- Name: users_user_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.users_user_id_seq OWNED BY public.users.user_id;


--
-- TOC entry 247 (class 1259 OID 17268)
-- Name: vw_stock_status; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.vw_stock_status AS
 SELECT i.item_id,
    i.item_name,
    u.uom_symbol,
    sb.available_quantity,
    sb.reserved_quantity,
    (sb.available_quantity + sb.reserved_quantity) AS total_on_hand,
    i.reorder_level,
        CASE
            WHEN (sb.available_quantity <= i.reorder_level) THEN true
            ELSE false
        END AS is_low_stock,
    sb.last_updated
   FROM ((public.stock_balance sb
     JOIN public.items i ON ((i.item_id = sb.item_id)))
     JOIN public.unit_of_measure u ON ((u.uom_id = i.uom_id)))
  WHERE (i.is_active = true);


ALTER VIEW public.vw_stock_status OWNER TO postgres;

--
-- TOC entry 252 (class 1259 OID 17293)
-- Name: vw_low_stock_alerts; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.vw_low_stock_alerts AS
 SELECT item_id,
    item_name,
    uom_symbol,
    available_quantity,
    reorder_level,
    (reorder_level - available_quantity) AS shortage_quantity,
    last_updated
   FROM public.vw_stock_status
  WHERE (is_low_stock = true)
  ORDER BY (reorder_level - available_quantity) DESC;


ALTER VIEW public.vw_low_stock_alerts OWNER TO postgres;

--
-- TOC entry 253 (class 1259 OID 17316)
-- Name: vw_admin_dashboard; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.vw_admin_dashboard AS
 SELECT ( SELECT count(*) AS count
           FROM public.sales_orders) AS total_sales_orders,
    ( SELECT count(*) AS count
           FROM public.sales_orders
          WHERE ((sales_orders.status)::text = 'Pending'::text)) AS so_pending,
    ( SELECT count(*) AS count
           FROM public.sales_orders
          WHERE ((sales_orders.status)::text = 'Processing'::text)) AS so_processing,
    ( SELECT count(*) AS count
           FROM public.sales_orders
          WHERE ((sales_orders.status)::text = 'Packed'::text)) AS so_packed,
    ( SELECT count(*) AS count
           FROM public.sales_orders
          WHERE ((sales_orders.status)::text = ANY ((ARRAY['Shipped'::character varying, 'Delivered'::character varying])::text[]))) AS so_completed,
    ( SELECT count(*) AS count
           FROM public.purchase_orders) AS total_purchase_orders,
    ( SELECT count(*) AS count
           FROM public.purchase_orders
          WHERE ((purchase_orders.status)::text = 'Pending'::text)) AS po_pending,
    ( SELECT count(*) AS count
           FROM public.purchase_orders
          WHERE ((purchase_orders.status)::text = 'Partially_Received'::text)) AS po_partial,
    ( SELECT count(*) AS count
           FROM public.vw_stock_status) AS total_items,
    ( SELECT count(*) AS count
           FROM public.vw_low_stock_alerts) AS low_stock_items,
    ( SELECT count(*) AS count
           FROM public.delivery_challans
          WHERE ((delivery_challans.status)::text = 'Dispatched'::text)) AS in_transit,
    ( SELECT COALESCE(sum((sol.shipped_quantity * sol.unit_price)), (0)::numeric) AS "coalesce"
           FROM (public.sales_order_lines sol
             JOIN public.sales_orders so ON ((so.so_id = sol.so_id)))
          WHERE ((so.payment_status)::text = 'Paid'::text)) AS revenue_collected,
    ( SELECT COALESCE(sum((sol.shipped_quantity * sol.unit_price)), (0)::numeric) AS "coalesce"
           FROM (public.sales_order_lines sol
             JOIN public.sales_orders so ON ((so.so_id = sol.so_id)))
          WHERE ((so.payment_status)::text = 'Unpaid'::text)) AS revenue_pending;


ALTER VIEW public.vw_admin_dashboard OWNER TO postgres;

--
-- TOC entry 251 (class 1259 OID 17288)
-- Name: vw_delivery_challan_full; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.vw_delivery_challan_full AS
 SELECT dc.dc_id,
    dc.so_id,
    dc.status AS dc_status,
    dc.driver_name,
    dc.vehicle_number,
    dc.dispatched_at,
    dc.delivered_at,
    dc.created_at,
    u.username AS created_by,
    c.customer_name,
    dcl.dc_line_id,
    i.item_id,
    i.item_name,
    dcl.shipped_quantity,
    um.uom_symbol
   FROM ((((((public.delivery_challans dc
     JOIN public.sales_orders so ON ((so.so_id = dc.so_id)))
     JOIN public.customers c ON ((c.customer_id = so.customer_id)))
     JOIN public.users u ON ((u.user_id = dc.created_by)))
     JOIN public.delivery_challan_lines dcl ON ((dcl.dc_id = dc.dc_id)))
     JOIN public.items i ON ((i.item_id = dcl.item_id)))
     JOIN public.unit_of_measure um ON ((um.uom_id = i.uom_id)));


ALTER VIEW public.vw_delivery_challan_full OWNER TO postgres;

--
-- TOC entry 249 (class 1259 OID 17278)
-- Name: vw_grn_full; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.vw_grn_full AS
 SELECT gr.grn_id,
    gr.po_id,
    gr.status AS grn_status,
    gr.received_at,
    u.username AS received_by,
    grl.grn_line_id,
    i.item_id,
    i.item_name,
    grl.received_quantity,
    um.uom_symbol
   FROM ((((public.goods_receipts gr
     JOIN public.users u ON ((u.user_id = gr.received_by)))
     JOIN public.goods_receipt_lines grl ON ((grl.grn_id = gr.grn_id)))
     JOIN public.items i ON ((i.item_id = grl.item_id)))
     JOIN public.unit_of_measure um ON ((um.uom_id = i.uom_id)));


ALTER VIEW public.vw_grn_full OWNER TO postgres;

--
-- TOC entry 248 (class 1259 OID 17273)
-- Name: vw_purchase_order_full; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.vw_purchase_order_full AS
 SELECT po.po_id,
    po.status AS po_status,
    po.created_at,
    po.updated_at,
    po.received_at,
    s.supplier_id,
    s.supplier_name,
    u.username AS created_by,
    pol.po_line_id,
    i.item_id,
    i.item_name,
    pol.ordered_quantity,
    pol.received_quantity,
    pol.pending_quantity,
    pol.unit_cost,
    pol.line_total,
    um.uom_symbol
   FROM (((((public.purchase_orders po
     JOIN public.suppliers s ON ((s.supplier_id = po.supplier_id)))
     JOIN public.users u ON ((u.user_id = po.created_by)))
     JOIN public.purchase_order_lines pol ON ((pol.po_id = po.po_id)))
     JOIN public.items i ON ((i.item_id = pol.item_id)))
     JOIN public.unit_of_measure um ON ((um.uom_id = i.uom_id)));


ALTER VIEW public.vw_purchase_order_full OWNER TO postgres;

--
-- TOC entry 250 (class 1259 OID 17283)
-- Name: vw_sales_order_full; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.vw_sales_order_full AS
 SELECT so.so_id,
    so.status AS so_status,
    so.payment_status,
    so.created_at,
    so.updated_at,
    c.customer_id,
    c.customer_name,
    c.phone AS customer_phone,
    u.username AS created_by,
    sol.so_line_id,
    i.item_id,
    i.item_name,
    sol.ordered_quantity,
    sol.shipped_quantity,
    sol.pending_quantity,
    sol.unit_price,
    sol.line_total,
    um.uom_symbol
   FROM (((((public.sales_orders so
     JOIN public.customers c ON ((c.customer_id = so.customer_id)))
     JOIN public.users u ON ((u.user_id = so.created_by)))
     JOIN public.sales_order_lines sol ON ((sol.so_id = so.so_id)))
     JOIN public.items i ON ((i.item_id = sol.item_id)))
     JOIN public.unit_of_measure um ON ((um.uom_id = i.uom_id)));


ALTER VIEW public.vw_sales_order_full OWNER TO postgres;

--
-- TOC entry 4871 (class 2604 OID 17031)
-- Name: customers customer_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customers ALTER COLUMN customer_id SET DEFAULT nextval('public.customers_customer_id_seq'::regclass);


--
-- TOC entry 4906 (class 2604 OID 17236)
-- Name: delivery_challan_lines dc_line_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_challan_lines ALTER COLUMN dc_line_id SET DEFAULT nextval('public.delivery_challan_lines_dc_line_id_seq'::regclass);


--
-- TOC entry 4903 (class 2604 OID 17214)
-- Name: delivery_challans dc_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_challans ALTER COLUMN dc_id SET DEFAULT nextval('public.delivery_challans_dc_id_seq'::regclass);


--
-- TOC entry 4866 (class 2604 OID 17000)
-- Name: document_types document_type_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.document_types ALTER COLUMN document_type_id SET DEFAULT nextval('public.document_types_document_type_id_seq'::regclass);


--
-- TOC entry 4892 (class 2604 OID 17144)
-- Name: goods_receipt_lines grn_line_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.goods_receipt_lines ALTER COLUMN grn_line_id SET DEFAULT nextval('public.goods_receipt_lines_grn_line_id_seq'::regclass);


--
-- TOC entry 4889 (class 2604 OID 17122)
-- Name: goods_receipts grn_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.goods_receipts ALTER COLUMN grn_id SET DEFAULT nextval('public.goods_receipts_grn_id_seq'::regclass);


--
-- TOC entry 4873 (class 2604 OID 17041)
-- Name: items item_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.items ALTER COLUMN item_id SET DEFAULT nextval('public.items_item_id_seq'::regclass);


--
-- TOC entry 4884 (class 2604 OID 17097)
-- Name: purchase_order_lines po_line_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchase_order_lines ALTER COLUMN po_line_id SET DEFAULT nextval('public.purchase_order_lines_po_line_id_seq'::regclass);


--
-- TOC entry 4880 (class 2604 OID 17074)
-- Name: purchase_orders po_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchase_orders ALTER COLUMN po_id SET DEFAULT nextval('public.purchase_orders_po_id_seq'::regclass);


--
-- TOC entry 4865 (class 2604 OID 16976)
-- Name: roles role_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.roles ALTER COLUMN role_id SET DEFAULT nextval('public.roles_role_id_seq'::regclass);


--
-- TOC entry 4898 (class 2604 OID 17189)
-- Name: sales_order_lines so_line_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_order_lines ALTER COLUMN so_line_id SET DEFAULT nextval('public.sales_order_lines_so_line_id_seq'::regclass);


--
-- TOC entry 4893 (class 2604 OID 17164)
-- Name: sales_orders so_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_orders ALTER COLUMN so_id SET DEFAULT nextval('public.sales_orders_so_id_seq'::regclass);


--
-- TOC entry 4868 (class 2604 OID 17020)
-- Name: suppliers supplier_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.suppliers ALTER COLUMN supplier_id SET DEFAULT nextval('public.suppliers_supplier_id_seq'::regclass);


--
-- TOC entry 4867 (class 2604 OID 17011)
-- Name: unit_of_measure uom_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.unit_of_measure ALTER COLUMN uom_id SET DEFAULT nextval('public.unit_of_measure_uom_id_seq'::regclass);


--
-- TOC entry 4862 (class 2604 OID 16963)
-- Name: users user_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users ALTER COLUMN user_id SET DEFAULT nextval('public.users_user_id_seq'::regclass);


--
-- TOC entry 5161 (class 0 OID 17028)
-- Dependencies: 227
-- Data for Name: customers; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.customers (customer_id, customer_name, phone, address, created_at) FROM stdin;
1	Ahmed Enterprises	0301-1111111	Karachi, Pakistan	2026-04-25 13:56:54.713055
2	Zara Goods	0312-2222222	Islamabad, Pakistan	2026-04-25 13:56:54.713055
\.


--
-- TOC entry 5180 (class 0 OID 17233)
-- Dependencies: 246
-- Data for Name: delivery_challan_lines; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.delivery_challan_lines (dc_line_id, dc_id, item_id, shipped_quantity) FROM stdin;
1	1	1	10.00
2	1	2	5.00
\.


--
-- TOC entry 5178 (class 0 OID 17211)
-- Dependencies: 244
-- Data for Name: delivery_challans; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.delivery_challans (dc_id, so_id, created_by, driver_name, vehicle_number, status, notes, dispatched_at, delivered_at, created_at) FROM stdin;
1	1	1	Ahmed Khan	LHR-789	Delivered	\N	2026-04-25 13:58:28.916984	2026-04-25 13:58:28.916984	2026-04-25 13:58:28.916984
\.


--
-- TOC entry 5155 (class 0 OID 16997)
-- Dependencies: 221
-- Data for Name: document_types; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.document_types (document_type_id, document_name, description) FROM stdin;
1	Purchase Order	Outgoing order sent to a supplier for goods.
2	Goods Receipt Note	Inbound receipt confirming supplier delivery.
3	Sales Order	Outbound order created on behalf of a customer.
4	Delivery Challan	Dispatch document assigning driver and vehicle to a shipment.
\.


--
-- TOC entry 5172 (class 0 OID 17141)
-- Dependencies: 238
-- Data for Name: goods_receipt_lines; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.goods_receipt_lines (grn_line_id, grn_id, item_id, received_quantity) FROM stdin;
1	1	1	100.00
2	1	2	50.00
\.


--
-- TOC entry 5170 (class 0 OID 17119)
-- Dependencies: 236
-- Data for Name: goods_receipts; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.goods_receipts (grn_id, po_id, received_by, status, notes, received_at) FROM stdin;
1	1	1	Confirmed	\N	2026-04-25 13:58:28.916984
\.


--
-- TOC entry 5163 (class 0 OID 17038)
-- Dependencies: 229
-- Data for Name: items; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.items (item_id, item_name, description, reorder_level, uom_id, is_active, created_at) FROM stdin;
1	Steel Rods	Construction steel rods	20.00	1	t	2026-04-25 13:56:54.713055
2	Cement Bags	50kg cement bags	10.00	2	t	2026-04-25 13:56:54.713055
3	Paint Cans	Industrial paint	5.00	3	t	2026-04-25 13:56:54.713055
\.


--
-- TOC entry 5168 (class 0 OID 17094)
-- Dependencies: 234
-- Data for Name: purchase_order_lines; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.purchase_order_lines (po_line_id, po_id, item_id, ordered_quantity, received_quantity, unit_cost) FROM stdin;
1	1	1	100.00	100.00	15.00
2	1	2	50.00	50.00	8.50
\.


--
-- TOC entry 5166 (class 0 OID 17071)
-- Dependencies: 232
-- Data for Name: purchase_orders; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.purchase_orders (po_id, supplier_id, created_by, status, notes, created_at, updated_at, received_at) FROM stdin;
1	1	1	Completed	\N	2026-04-25 13:58:28.916984	2026-04-25 13:58:28.916984	2026-04-25 13:58:28.916984
\.


--
-- TOC entry 5152 (class 0 OID 16973)
-- Dependencies: 218
-- Data for Name: roles; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.roles (role_id, role_name) FROM stdin;
1	Administrator
2	Warehouse Staff
3	Logistics Staff
\.


--
-- TOC entry 5176 (class 0 OID 17186)
-- Dependencies: 242
-- Data for Name: sales_order_lines; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.sales_order_lines (so_line_id, so_id, item_id, ordered_quantity, shipped_quantity, unit_price) FROM stdin;
1	1	1	10.00	10.00	25.00
2	1	2	5.00	5.00	12.00
\.


--
-- TOC entry 5174 (class 0 OID 17161)
-- Dependencies: 240
-- Data for Name: sales_orders; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.sales_orders (so_id, customer_id, created_by, status, payment_status, notes, created_at, updated_at) FROM stdin;
1	1	1	Delivered	Unpaid	\N	2026-04-25 13:58:28.916984	2026-04-25 13:58:28.916984
\.


--
-- TOC entry 5164 (class 0 OID 17055)
-- Dependencies: 230
-- Data for Name: stock_balance; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.stock_balance (item_id, available_quantity, reserved_quantity, last_updated) FROM stdin;
3	0.00	0.00	2026-04-25 13:56:54.713055
1	90.00	0.00	2026-04-25 13:58:28.916984
2	45.00	0.00	2026-04-25 13:58:28.916984
\.


--
-- TOC entry 5159 (class 0 OID 17017)
-- Dependencies: 225
-- Data for Name: suppliers; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.suppliers (supplier_id, supplier_name, email, phone, address, is_active, created_at) FROM stdin;
1	Alpha Traders	alpha@traders.com	0311-1234567	Karachi, Pakistan	t	2026-04-25 13:56:54.713055
2	Beta Supplies	beta@supplies.com	0321-7654321	Lahore, Pakistan	t	2026-04-25 13:56:54.713055
\.


--
-- TOC entry 5157 (class 0 OID 17008)
-- Dependencies: 223
-- Data for Name: unit_of_measure; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.unit_of_measure (uom_id, uom_name, uom_symbol) FROM stdin;
1	Kilogram	kg
2	Pieces	pcs
3	Liters	L
4	Meters	m
5	Boxes	box
\.


--
-- TOC entry 5153 (class 0 OID 16981)
-- Dependencies: 219
-- Data for Name: user_roles; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.user_roles (user_id, role_id) FROM stdin;
1	1
2	2
3	3
\.


--
-- TOC entry 5150 (class 0 OID 16960)
-- Dependencies: 216
-- Data for Name: users; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.users (user_id, username, password_hash, is_active, created_at) FROM stdin;
1	admin	hashed_password_1	t	2026-04-25 13:56:54.713055
2	warehouse	hashed_password_2	t	2026-04-25 13:56:54.713055
3	logistics	hashed_password_3	t	2026-04-25 13:56:54.713055
\.


--
-- TOC entry 5201 (class 0 OID 0)
-- Dependencies: 226
-- Name: customers_customer_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.customers_customer_id_seq', 2, true);


--
-- TOC entry 5202 (class 0 OID 0)
-- Dependencies: 245
-- Name: delivery_challan_lines_dc_line_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.delivery_challan_lines_dc_line_id_seq', 2, true);


--
-- TOC entry 5203 (class 0 OID 0)
-- Dependencies: 243
-- Name: delivery_challans_dc_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.delivery_challans_dc_id_seq', 1, true);


--
-- TOC entry 5204 (class 0 OID 0)
-- Dependencies: 220
-- Name: document_types_document_type_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.document_types_document_type_id_seq', 4, true);


--
-- TOC entry 5205 (class 0 OID 0)
-- Dependencies: 237
-- Name: goods_receipt_lines_grn_line_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.goods_receipt_lines_grn_line_id_seq', 2, true);


--
-- TOC entry 5206 (class 0 OID 0)
-- Dependencies: 235
-- Name: goods_receipts_grn_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.goods_receipts_grn_id_seq', 1, true);


--
-- TOC entry 5207 (class 0 OID 0)
-- Dependencies: 228
-- Name: items_item_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.items_item_id_seq', 3, true);


--
-- TOC entry 5208 (class 0 OID 0)
-- Dependencies: 233
-- Name: purchase_order_lines_po_line_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.purchase_order_lines_po_line_id_seq', 2, true);


--
-- TOC entry 5209 (class 0 OID 0)
-- Dependencies: 231
-- Name: purchase_orders_po_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.purchase_orders_po_id_seq', 1, true);


--
-- TOC entry 5210 (class 0 OID 0)
-- Dependencies: 217
-- Name: roles_role_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.roles_role_id_seq', 3, true);


--
-- TOC entry 5211 (class 0 OID 0)
-- Dependencies: 241
-- Name: sales_order_lines_so_line_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.sales_order_lines_so_line_id_seq', 2, true);


--
-- TOC entry 5212 (class 0 OID 0)
-- Dependencies: 239
-- Name: sales_orders_so_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.sales_orders_so_id_seq', 1, true);


--
-- TOC entry 5213 (class 0 OID 0)
-- Dependencies: 224
-- Name: suppliers_supplier_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.suppliers_supplier_id_seq', 2, true);


--
-- TOC entry 5214 (class 0 OID 0)
-- Dependencies: 222
-- Name: unit_of_measure_uom_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.unit_of_measure_uom_id_seq', 5, true);


--
-- TOC entry 5215 (class 0 OID 0)
-- Dependencies: 215
-- Name: users_user_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.users_user_id_seq', 5, true);


--
-- TOC entry 4942 (class 2606 OID 17036)
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (customer_id);


--
-- TOC entry 4968 (class 2606 OID 17241)
-- Name: delivery_challan_lines delivery_challan_lines_dc_id_item_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_challan_lines
    ADD CONSTRAINT delivery_challan_lines_dc_id_item_id_key UNIQUE (dc_id, item_id);


--
-- TOC entry 4970 (class 2606 OID 17239)
-- Name: delivery_challan_lines delivery_challan_lines_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_challan_lines
    ADD CONSTRAINT delivery_challan_lines_pkey PRIMARY KEY (dc_line_id);


--
-- TOC entry 4966 (class 2606 OID 17221)
-- Name: delivery_challans delivery_challans_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_challans
    ADD CONSTRAINT delivery_challans_pkey PRIMARY KEY (dc_id);


--
-- TOC entry 4932 (class 2606 OID 17006)
-- Name: document_types document_types_document_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.document_types
    ADD CONSTRAINT document_types_document_name_key UNIQUE (document_name);


--
-- TOC entry 4934 (class 2606 OID 17004)
-- Name: document_types document_types_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.document_types
    ADD CONSTRAINT document_types_pkey PRIMARY KEY (document_type_id);


--
-- TOC entry 4956 (class 2606 OID 17149)
-- Name: goods_receipt_lines goods_receipt_lines_grn_id_item_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.goods_receipt_lines
    ADD CONSTRAINT goods_receipt_lines_grn_id_item_id_key UNIQUE (grn_id, item_id);


--
-- TOC entry 4958 (class 2606 OID 17147)
-- Name: goods_receipt_lines goods_receipt_lines_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.goods_receipt_lines
    ADD CONSTRAINT goods_receipt_lines_pkey PRIMARY KEY (grn_line_id);


--
-- TOC entry 4954 (class 2606 OID 17129)
-- Name: goods_receipts goods_receipts_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.goods_receipts
    ADD CONSTRAINT goods_receipts_pkey PRIMARY KEY (grn_id);


--
-- TOC entry 4944 (class 2606 OID 17049)
-- Name: items items_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.items
    ADD CONSTRAINT items_pkey PRIMARY KEY (item_id);


--
-- TOC entry 4950 (class 2606 OID 17105)
-- Name: purchase_order_lines purchase_order_lines_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchase_order_lines
    ADD CONSTRAINT purchase_order_lines_pkey PRIMARY KEY (po_line_id);


--
-- TOC entry 4952 (class 2606 OID 17107)
-- Name: purchase_order_lines purchase_order_lines_po_id_item_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchase_order_lines
    ADD CONSTRAINT purchase_order_lines_po_id_item_id_key UNIQUE (po_id, item_id);


--
-- TOC entry 4948 (class 2606 OID 17082)
-- Name: purchase_orders purchase_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchase_orders
    ADD CONSTRAINT purchase_orders_pkey PRIMARY KEY (po_id);


--
-- TOC entry 4926 (class 2606 OID 16978)
-- Name: roles roles_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_pkey PRIMARY KEY (role_id);


--
-- TOC entry 4928 (class 2606 OID 16980)
-- Name: roles roles_role_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_role_name_key UNIQUE (role_name);


--
-- TOC entry 4962 (class 2606 OID 17197)
-- Name: sales_order_lines sales_order_lines_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_order_lines
    ADD CONSTRAINT sales_order_lines_pkey PRIMARY KEY (so_line_id);


--
-- TOC entry 4964 (class 2606 OID 17199)
-- Name: sales_order_lines sales_order_lines_so_id_item_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_order_lines
    ADD CONSTRAINT sales_order_lines_so_id_item_id_key UNIQUE (so_id, item_id);


--
-- TOC entry 4960 (class 2606 OID 17174)
-- Name: sales_orders sales_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_orders
    ADD CONSTRAINT sales_orders_pkey PRIMARY KEY (so_id);


--
-- TOC entry 4946 (class 2606 OID 17064)
-- Name: stock_balance stock_balance_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.stock_balance
    ADD CONSTRAINT stock_balance_pkey PRIMARY KEY (item_id);


--
-- TOC entry 4940 (class 2606 OID 17026)
-- Name: suppliers suppliers_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.suppliers
    ADD CONSTRAINT suppliers_pkey PRIMARY KEY (supplier_id);


--
-- TOC entry 4936 (class 2606 OID 17013)
-- Name: unit_of_measure unit_of_measure_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.unit_of_measure
    ADD CONSTRAINT unit_of_measure_pkey PRIMARY KEY (uom_id);


--
-- TOC entry 4938 (class 2606 OID 17015)
-- Name: unit_of_measure unit_of_measure_uom_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.unit_of_measure
    ADD CONSTRAINT unit_of_measure_uom_name_key UNIQUE (uom_name);


--
-- TOC entry 4930 (class 2606 OID 16985)
-- Name: user_roles user_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT user_roles_pkey PRIMARY KEY (user_id, role_id);


--
-- TOC entry 4922 (class 2606 OID 16969)
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (user_id);


--
-- TOC entry 4924 (class 2606 OID 16971)
-- Name: users users_username_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_username_key UNIQUE (username);


--
-- TOC entry 4997 (class 2620 OID 17262)
-- Name: delivery_challans trg_dc_delivered; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_dc_delivered AFTER UPDATE OF status ON public.delivery_challans FOR EACH ROW EXECUTE FUNCTION public.fn_dc_delivered();


--
-- TOC entry 4998 (class 2620 OID 17260)
-- Name: delivery_challans trg_dc_dispatched; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_dc_dispatched AFTER UPDATE OF status ON public.delivery_challans FOR EACH ROW EXECUTE FUNCTION public.fn_dc_dispatched();


--
-- TOC entry 4994 (class 2620 OID 17256)
-- Name: goods_receipts trg_grn_confirm_stock; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_grn_confirm_stock AFTER UPDATE OF status ON public.goods_receipts FOR EACH ROW EXECUTE FUNCTION public.fn_grn_confirm_stock();


--
-- TOC entry 4991 (class 2620 OID 17254)
-- Name: items trg_init_stock_balance; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_init_stock_balance AFTER INSERT ON public.items FOR EACH ROW EXECUTE FUNCTION public.fn_init_stock_balance();


--
-- TOC entry 4993 (class 2620 OID 17265)
-- Name: purchase_orders trg_po_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_po_updated_at BEFORE UPDATE ON public.purchase_orders FOR EACH ROW EXECUTE FUNCTION public.fn_stamp_updated_at();


--
-- TOC entry 4996 (class 2620 OID 17258)
-- Name: sales_order_lines trg_so_line_reserve_stock; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_so_line_reserve_stock AFTER INSERT ON public.sales_order_lines FOR EACH ROW EXECUTE FUNCTION public.fn_so_line_reserve_stock();


--
-- TOC entry 4995 (class 2620 OID 17264)
-- Name: sales_orders trg_so_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_so_updated_at BEFORE UPDATE ON public.sales_orders FOR EACH ROW EXECUTE FUNCTION public.fn_stamp_updated_at();


--
-- TOC entry 4992 (class 2620 OID 17267)
-- Name: stock_balance trg_stock_last_updated; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_stock_last_updated BEFORE UPDATE ON public.stock_balance FOR EACH ROW EXECUTE FUNCTION public.fn_stamp_stock_last_updated();


--
-- TOC entry 4989 (class 2606 OID 17242)
-- Name: delivery_challan_lines delivery_challan_lines_dc_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_challan_lines
    ADD CONSTRAINT delivery_challan_lines_dc_id_fkey FOREIGN KEY (dc_id) REFERENCES public.delivery_challans(dc_id) ON DELETE CASCADE;


--
-- TOC entry 4990 (class 2606 OID 17247)
-- Name: delivery_challan_lines delivery_challan_lines_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_challan_lines
    ADD CONSTRAINT delivery_challan_lines_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(item_id);


--
-- TOC entry 4987 (class 2606 OID 17227)
-- Name: delivery_challans delivery_challans_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_challans
    ADD CONSTRAINT delivery_challans_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 4988 (class 2606 OID 17222)
-- Name: delivery_challans delivery_challans_so_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_challans
    ADD CONSTRAINT delivery_challans_so_id_fkey FOREIGN KEY (so_id) REFERENCES public.sales_orders(so_id);


--
-- TOC entry 4981 (class 2606 OID 17150)
-- Name: goods_receipt_lines goods_receipt_lines_grn_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.goods_receipt_lines
    ADD CONSTRAINT goods_receipt_lines_grn_id_fkey FOREIGN KEY (grn_id) REFERENCES public.goods_receipts(grn_id) ON DELETE CASCADE;


--
-- TOC entry 4982 (class 2606 OID 17155)
-- Name: goods_receipt_lines goods_receipt_lines_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.goods_receipt_lines
    ADD CONSTRAINT goods_receipt_lines_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(item_id);


--
-- TOC entry 4979 (class 2606 OID 17130)
-- Name: goods_receipts goods_receipts_po_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.goods_receipts
    ADD CONSTRAINT goods_receipts_po_id_fkey FOREIGN KEY (po_id) REFERENCES public.purchase_orders(po_id);


--
-- TOC entry 4980 (class 2606 OID 17135)
-- Name: goods_receipts goods_receipts_received_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.goods_receipts
    ADD CONSTRAINT goods_receipts_received_by_fkey FOREIGN KEY (received_by) REFERENCES public.users(user_id);


--
-- TOC entry 4973 (class 2606 OID 17050)
-- Name: items items_uom_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.items
    ADD CONSTRAINT items_uom_id_fkey FOREIGN KEY (uom_id) REFERENCES public.unit_of_measure(uom_id);


--
-- TOC entry 4977 (class 2606 OID 17113)
-- Name: purchase_order_lines purchase_order_lines_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchase_order_lines
    ADD CONSTRAINT purchase_order_lines_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(item_id);


--
-- TOC entry 4978 (class 2606 OID 17108)
-- Name: purchase_order_lines purchase_order_lines_po_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchase_order_lines
    ADD CONSTRAINT purchase_order_lines_po_id_fkey FOREIGN KEY (po_id) REFERENCES public.purchase_orders(po_id) ON DELETE CASCADE;


--
-- TOC entry 4975 (class 2606 OID 17088)
-- Name: purchase_orders purchase_orders_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchase_orders
    ADD CONSTRAINT purchase_orders_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 4976 (class 2606 OID 17083)
-- Name: purchase_orders purchase_orders_supplier_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchase_orders
    ADD CONSTRAINT purchase_orders_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES public.suppliers(supplier_id);


--
-- TOC entry 4985 (class 2606 OID 17205)
-- Name: sales_order_lines sales_order_lines_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_order_lines
    ADD CONSTRAINT sales_order_lines_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(item_id);


--
-- TOC entry 4986 (class 2606 OID 17200)
-- Name: sales_order_lines sales_order_lines_so_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_order_lines
    ADD CONSTRAINT sales_order_lines_so_id_fkey FOREIGN KEY (so_id) REFERENCES public.sales_orders(so_id) ON DELETE CASCADE;


--
-- TOC entry 4983 (class 2606 OID 17180)
-- Name: sales_orders sales_orders_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_orders
    ADD CONSTRAINT sales_orders_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 4984 (class 2606 OID 17175)
-- Name: sales_orders sales_orders_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_orders
    ADD CONSTRAINT sales_orders_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 4974 (class 2606 OID 17065)
-- Name: stock_balance stock_balance_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.stock_balance
    ADD CONSTRAINT stock_balance_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(item_id);


--
-- TOC entry 4971 (class 2606 OID 16991)
-- Name: user_roles user_roles_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT user_roles_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.roles(role_id) ON DELETE CASCADE;


--
-- TOC entry 4972 (class 2606 OID 16986)
-- Name: user_roles user_roles_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT user_roles_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id) ON DELETE CASCADE;


-- Completed on 2026-04-25 15:19:00

--
-- PostgreSQL database dump complete
--

\unrestrict zZDShmrAMfqkSJaCyCOaKUp0NvPQmbeFCi2x1Cfi7XO1cTehJ4qUcV6zFGKZMYv


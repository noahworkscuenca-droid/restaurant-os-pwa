-- FASE 1: Supabase Auth + roles + autoria (idempotente, seguro de re-ejecutar)
-- Aplicar en: Supabase > SQL Editor > pegar todo > Run
CREATE TABLE IF NOT EXISTS profiles (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  name text NOT NULL DEFAULT 'Usuario',
  role text NOT NULL DEFAULT 'empleado' CHECK (role IN ('admin','empleado')),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz DEFAULT now()
);
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoices ADD COLUMN IF NOT EXISTS created_by uuid;

CREATE OR REPLACE FUNCTION handle_new_user() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ok boolean; v_first boolean;
BEGIN
  SELECT EXISTS (SELECT 1 FROM access_codes
    WHERE active AND code_hash = extensions.crypt(coalesce(NEW.raw_user_meta_data->>'invite',''), code_hash)) INTO v_ok;
  SELECT NOT EXISTS (SELECT 1 FROM profiles) INTO v_first;
  INSERT INTO profiles (user_id, name, role, active)
  VALUES (NEW.id, coalesce(NULLIF(trim(NEW.raw_user_meta_data->>'name'),''),'Usuario'),
          CASE WHEN v_first THEN 'admin' ELSE 'empleado' END, v_first OR v_ok);
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION handle_new_user();

CREATE OR REPLACE FUNCTION _check_code(p_code text) RETURNS boolean
LANGUAGE sql SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT (auth.uid() IS NOT NULL AND EXISTS (SELECT 1 FROM profiles WHERE user_id = auth.uid() AND active))
      OR EXISTS (SELECT 1 FROM access_codes WHERE active AND code_hash = extensions.crypt(p_code, code_hash));
$$;

CREATE OR REPLACE FUNCTION _is_admin() RETURNS boolean
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT auth.uid() IS NULL
      OR EXISTS (SELECT 1 FROM profiles WHERE user_id = auth.uid() AND active AND role = 'admin');
$$;

CREATE OR REPLACE FUNCTION api_me() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r record;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('ok', false); END IF;
  SELECT * INTO r FROM profiles WHERE user_id = auth.uid();
  IF r IS NULL THEN RETURN jsonb_build_object('ok', false); END IF;
  RETURN jsonb_build_object('ok', true, 'name', r.name, 'role', r.role, 'active', r.active);
END $$;

CREATE OR REPLACE FUNCTION api_save_invoice(p_code text, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_sup uuid; v_cat smallint; v_id uuid; v_date date; v_total numeric;
BEGIN
  IF NOT _check_code(p_code) THEN RETURN jsonb_build_object('ok', false, 'error', 'codigo_invalido'); END IF;
  BEGIN v_date := NULLIF(trim(p->>'invoice_date'),'')::date; EXCEPTION WHEN others THEN v_date := NULL; END;
  v_date := COALESCE(v_date, CURRENT_DATE);
  BEGIN v_total := NULLIF(trim(p->>'total_amount'),'')::numeric; EXCEPTION WHEN others THEN v_total := NULL; END;
  IF v_total IS NULL OR v_total <= 0 THEN RETURN jsonb_build_object('ok', false, 'error', 'monto_invalido'); END IF;
  SELECT id INTO v_sup FROM suppliers WHERE lower(name) = lower(trim(coalesce(p->>'supplier_name',''))) LIMIT 1;
  IF v_sup IS NULL THEN
    INSERT INTO suppliers (name) VALUES (COALESCE(NULLIF(trim(p->>'supplier_name'),''),'Sin proveedor')) RETURNING id INTO v_sup;
  END IF;
  SELECT id INTO v_cat FROM invoice_categories WHERE lower(name) = lower(coalesce(p->>'category','')) LIMIT 1;
  IF v_cat IS NULL THEN SELECT id INTO v_cat FROM invoice_categories WHERE name = 'Otros' LIMIT 1; END IF;
  INSERT INTO invoices (supplier_id, invoice_number, invoice_date, category_id, sale_type,
                        total_amount, currency, status, image_url, image_path, ocr_confidence, needs_review, created_by)
  VALUES (v_sup, NULLIF(trim(coalesce(p->>'invoice_number','')),''), v_date, v_cat,
          CASE WHEN upper(coalesce(p->>'sale_type','')) = 'CREDITO' THEN 'CREDITO' ELSE 'CONTADO' END,
          v_total, 'CRC', 'PENDIENTE',
          NULLIF(p->>'image_url',''), NULLIF(p->>'image_path',''),
          (SELECT x::numeric FROM (SELECT NULLIF(trim(coalesce(p->>'ocr_confidence','')),'') x) s WHERE x ~ '^[0-9.]+$'),
          COALESCE((p->>'needs_review') IN ('true','t','1'), false), auth.uid())
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok', true, 'id', v_id);
EXCEPTION WHEN others THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END $$;

CREATE OR REPLACE FUNCTION api_list_invoices(p_code text, p_limit int DEFAULT 200, p_month text DEFAULT NULL,
  p_supplier uuid DEFAULT NULL, p_status text DEFAULT NULL, p_q text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  IF NOT _check_code(p_code) THEN RETURN jsonb_build_object('ok', false, 'error', 'codigo_invalido'); END IF;
  RETURN (WITH f AS (
    SELECT i.*, s.name AS supplier_name, c.name AS category, pr.name AS created_by_name
    FROM invoices i
    LEFT JOIN suppliers s ON s.id = i.supplier_id
    LEFT JOIN invoice_categories c ON c.id = i.category_id
    LEFT JOIN profiles pr ON pr.user_id = i.created_by
    WHERE i.status IS DISTINCT FROM 'ANULADA'
      AND (p_month IS NULL OR to_char(i.invoice_date,'YYYY-MM') = p_month)
      AND (p_supplier IS NULL OR i.supplier_id = p_supplier)
      AND (p_status IS NULL OR i.status = p_status)
      AND (p_q IS NULL OR i.invoice_number ILIKE '%'||p_q||'%')
  )
  SELECT jsonb_build_object('ok', true,
    'total', COALESCE((SELECT sum(total_amount) FROM f), 0),
    'pending', COALESCE((SELECT sum(total_amount) FROM f WHERE status = 'PENDIENTE'), 0),
    'rows', COALESCE((SELECT jsonb_agg(r) FROM (
      SELECT id, invoice_number, invoice_date, total_amount, sale_type, status,
             image_url, supplier_name, supplier_id, category, created_by_name
      FROM f ORDER BY invoice_date DESC, created_at DESC LIMIT p_limit) r), '[]'::jsonb)));
END $$;

CREATE OR REPLACE FUNCTION api_delete_invoice(p_code text, p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  IF NOT _check_code(p_code) THEN RETURN jsonb_build_object('ok', false, 'error', 'codigo_invalido'); END IF;
  IF NOT _is_admin() THEN RETURN jsonb_build_object('ok', false, 'error', 'solo_admin'); END IF;
  UPDATE invoices SET status = 'ANULADA', updated_at = now() WHERE id = p_id;
  RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION api_change_code(p_old text, p_new text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  IF auth.uid() IS NOT NULL THEN
    IF NOT _is_admin() THEN RETURN jsonb_build_object('ok', false, 'error', 'solo_admin'); END IF;
  ELSIF NOT _check_code(p_old) THEN RETURN jsonb_build_object('ok', false, 'error', 'codigo_invalido');
  END IF;
  IF length(trim(p_new)) < 6 THEN RETURN jsonb_build_object('ok', false, 'error', 'minimo_6_caracteres'); END IF;
  UPDATE access_codes SET code_hash = extensions.crypt(trim(p_new), extensions.gen_salt('bf')) WHERE active;
  RETURN jsonb_build_object('ok', true);
END $$;

GRANT EXECUTE ON FUNCTION api_me() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION api_verify_code(text), api_save_invoice(text, jsonb),
  api_list_invoices(text,int,text,uuid,text,text), api_dashboard(text), api_change_code(text,text),
  api_list_suppliers(text), api_update_supplier(text,uuid,text),
  api_update_invoice(text,uuid,jsonb), api_delete_invoice(text,uuid) TO authenticated;
NOTIFY pgrst, 'reload schema';

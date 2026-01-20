/*
  # Enhanced Purchase Invoice System - Tally-Style Professional Accounting

  ## Summary
  This migration enhances the Purchase Invoice system to support multi-type purchases
  with proper accounting treatment for Inventory, Fixed Assets, Expenses, and Imports.

  ## Changes Made
  1. Add purchase_type to purchase_invoices table
  2. Add item_type and expense_account_id to purchase_invoice_items  
  3. Update journal posting trigger to handle different item types
  4. Add Directors table for capital contributions
  5. NO DATA IS DELETED OR MODIFIED - only new columns added

  ## Safety
  - All existing data remains intact
  - New columns have DEFAULT values
  - Existing triggers updated to handle new fields
  - Can be rolled back if needed
*/

-- ============================================
-- 1. ENHANCE PURCHASE INVOICES TABLE
-- ============================================

-- Add purchase_type to categorize the purchase
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'purchase_invoices' AND column_name = 'purchase_type'
  ) THEN
    ALTER TABLE purchase_invoices 
    ADD COLUMN purchase_type VARCHAR(50) DEFAULT 'inventory' 
    CHECK (purchase_type IN ('inventory', 'fixed_asset', 'expense', 'import'));
  END IF;
END $$;

-- Add supplier NPWP display flag (for Faktur Pajak)
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'purchase_invoices' AND column_name = 'requires_faktur_pajak'
  ) THEN
    ALTER TABLE purchase_invoices 
    ADD COLUMN requires_faktur_pajak BOOLEAN DEFAULT false;
  END IF;
END $$;

COMMENT ON COLUMN purchase_invoices.purchase_type IS 'Type of purchase: inventory (stock), fixed_asset, expense, or import';
COMMENT ON COLUMN purchase_invoices.requires_faktur_pajak IS 'True if supplier is PKP and Faktur Pajak is required';

-- ============================================
-- 2. ENHANCE PURCHASE INVOICE ITEMS TABLE
-- ============================================

-- Add item_type to specify what each line item represents
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'purchase_invoice_items' AND column_name = 'item_type'
  ) THEN
    ALTER TABLE purchase_invoice_items 
    ADD COLUMN item_type VARCHAR(50) DEFAULT 'inventory' 
    CHECK (item_type IN ('inventory', 'fixed_asset', 'expense', 'freight', 'duty', 'insurance', 'clearing', 'other'));
  END IF;
END $$;

-- Add expense_account_id for expense line items
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'purchase_invoice_items' AND column_name = 'expense_account_id'
  ) THEN
    ALTER TABLE purchase_invoice_items 
    ADD COLUMN expense_account_id UUID REFERENCES chart_of_accounts(id);
  END IF;
END $$;

-- Add asset_account_id for fixed asset items
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'purchase_invoice_items' AND column_name = 'asset_account_id'
  ) THEN
    ALTER TABLE purchase_invoice_items 
    ADD COLUMN asset_account_id UUID REFERENCES chart_of_accounts(id);
  END IF;
END $$;

COMMENT ON COLUMN purchase_invoice_items.item_type IS 'Type: inventory, fixed_asset, expense, freight, duty, insurance, clearing, other';
COMMENT ON COLUMN purchase_invoice_items.expense_account_id IS 'Chart of Account for expense items';
COMMENT ON COLUMN purchase_invoice_items.asset_account_id IS 'Chart of Account for fixed asset items';

-- Create index for better performance
CREATE INDEX IF NOT EXISTS idx_pii_expense_account ON purchase_invoice_items(expense_account_id);
CREATE INDEX IF NOT EXISTS idx_pii_asset_account ON purchase_invoice_items(asset_account_id);
CREATE INDEX IF NOT EXISTS idx_pii_item_type ON purchase_invoice_items(item_type);

-- ============================================
-- 3. CREATE DIRECTORS TABLE FOR CAPITAL CONTRIBUTIONS
-- ============================================

CREATE TABLE IF NOT EXISTS directors (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  director_code VARCHAR(50) UNIQUE,
  full_name VARCHAR(255) NOT NULL,
  designation VARCHAR(100), -- Managing Director, Director, Partner, etc.
  email VARCHAR(255),
  phone VARCHAR(50),
  address TEXT,
  capital_account_id UUID REFERENCES chart_of_accounts(id), -- Dedicated capital ledger
  is_active BOOLEAN DEFAULT true,
  notes TEXT,
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_directors_name ON directors(full_name);
CREATE INDEX IF NOT EXISTS idx_directors_capital_account ON directors(capital_account_id);

COMMENT ON TABLE directors IS 'Directors/Partners master for capital contribution tracking';
COMMENT ON COLUMN directors.capital_account_id IS 'Dedicated capital ledger account (Equity section)';

-- ============================================
-- 4. CREATE CAPITAL CONTRIBUTION VOUCHERS TABLE  
-- ============================================

CREATE TABLE IF NOT EXISTS capital_contributions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  voucher_number VARCHAR(50) NOT NULL UNIQUE,
  voucher_date DATE NOT NULL,
  director_id UUID NOT NULL REFERENCES directors(id),
  contribution_type VARCHAR(50) NOT NULL CHECK (contribution_type IN ('cash', 'bank_transfer', 'asset', 'other')),
  bank_account_id UUID REFERENCES bank_accounts(id),
  amount DECIMAL(18,2) NOT NULL,
  description TEXT,
  document_urls TEXT[],
  journal_entry_id UUID REFERENCES journal_entries(id),
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_cc_director ON capital_contributions(director_id);
CREATE INDEX IF NOT EXISTS idx_cc_date ON capital_contributions(voucher_date);
CREATE INDEX IF NOT EXISTS idx_cc_journal ON capital_contributions(journal_entry_id);

COMMENT ON TABLE capital_contributions IS 'Director capital contributions (Dr Bank/Cash, Cr Owner Capital)';

-- ============================================
-- 5. UPDATE PURCHASE INVOICE JOURNAL POSTING TRIGGER
-- ============================================

CREATE OR REPLACE FUNCTION post_purchase_invoice_journal()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_je_id UUID;
  v_je_number TEXT;
  v_ap_account_id UUID;
  v_ppn_account_id UUID;
  v_line_number INTEGER := 1;
  v_item RECORD;
  v_account_id UUID;
BEGIN
  -- Only create journal on insert or when journal doesn't exist yet
  IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND OLD.journal_entry_id IS NULL AND NEW.status IN ('unpaid', 'partial', 'paid')) THEN
    
    -- Get Accounts Payable and PPN Input accounts
    SELECT id INTO v_ap_account_id FROM chart_of_accounts WHERE code = '2110' LIMIT 1;
    SELECT id INTO v_ppn_account_id FROM chart_of_accounts WHERE code = '1150' LIMIT 1;

    IF v_ap_account_id IS NULL THEN
      RAISE NOTICE 'Accounts Payable account (2110) not found';
      RETURN NEW;
    END IF;

    -- Generate journal entry number
    v_je_number := 'JE-' || TO_CHAR(NEW.invoice_date, 'YYMM') || '-' || LPAD((
      SELECT COALESCE(MAX(CAST(SUBSTRING(entry_number FROM '(\d+)$') AS INTEGER)), 0) + 1
      FROM journal_entries 
      WHERE entry_number LIKE 'JE-' || TO_CHAR(NEW.invoice_date, 'YYMM') || '-%'
    )::TEXT, 4, '0');

    -- Create journal entry header
    INSERT INTO journal_entries (
      entry_number, entry_date, source_module, reference_id, reference_number,
      description, total_debit, total_credit, is_posted, posted_by, created_by
    ) VALUES (
      v_je_number, NEW.invoice_date, 'purchase_invoice', NEW.id, NEW.invoice_number,
      'Purchase Invoice: ' || NEW.invoice_number,
      NEW.total_amount, NEW.total_amount, true, NEW.created_by, NEW.created_by
    ) RETURNING id INTO v_je_id;

    -- Loop through purchase invoice items and create debit entries
    FOR v_item IN 
      SELECT * FROM purchase_invoice_items 
      WHERE purchase_invoice_id = NEW.id 
      ORDER BY id
    LOOP
      -- Determine which account to debit based on item_type
      IF v_item.item_type = 'inventory' THEN
        -- Inventory items go to Inventory account (1130)
        SELECT id INTO v_account_id FROM chart_of_accounts WHERE code = '1130' LIMIT 1;
        
      ELSIF v_item.item_type = 'fixed_asset' THEN
        -- Fixed assets use specified asset account or default Fixed Assets account
        v_account_id := v_item.asset_account_id;
        IF v_account_id IS NULL THEN
          SELECT id INTO v_account_id FROM chart_of_accounts WHERE code = '1200' LIMIT 1;
        END IF;
        
      ELSIF v_item.item_type IN ('expense', 'freight', 'duty', 'insurance', 'clearing', 'other') THEN
        -- Expense items use specified expense account
        v_account_id := v_item.expense_account_id;
        IF v_account_id IS NULL THEN
          -- Default to general expenses if no account specified
          SELECT id INTO v_account_id FROM chart_of_accounts WHERE code = '5100' LIMIT 1;
        END IF;
      END IF;

      -- Create debit line for this item
      IF v_account_id IS NOT NULL THEN
        INSERT INTO journal_entry_lines (
          journal_entry_id, line_number, account_id, description, 
          debit, credit, supplier_id, batch_id
        ) VALUES (
          v_je_id, v_line_number, v_account_id, 
          COALESCE(v_item.description, 'Purchase - ' || NEW.invoice_number),
          v_item.line_total, 0, NEW.supplier_id, v_item.batch_id
        );
        v_line_number := v_line_number + 1;
      END IF;
    END LOOP;

    -- Debit: PPN Input (if applicable)
    IF NEW.tax_amount > 0 AND v_ppn_account_id IS NOT NULL THEN
      INSERT INTO journal_entry_lines (
        journal_entry_id, line_number, account_id, description, 
        debit, credit, supplier_id
      ) VALUES (
        v_je_id, v_line_number, v_ppn_account_id, 
        'PPN Input - ' || NEW.invoice_number,
        NEW.tax_amount, 0, NEW.supplier_id
      );
      v_line_number := v_line_number + 1;
    END IF;

    -- Credit: Accounts Payable (total amount)
    INSERT INTO journal_entry_lines (
      journal_entry_id, line_number, account_id, description, 
      debit, credit, supplier_id
    ) VALUES (
      v_je_id, v_line_number, v_ap_account_id, 
      'A/P - ' || NEW.invoice_number,
      0, NEW.total_amount, NEW.supplier_id
    );

    -- Update purchase invoice with journal entry ID
    NEW.journal_entry_id := v_je_id;
  END IF;

  RETURN NEW;
END;
$$;

-- Recreate trigger (DROP IF EXISTS first to avoid errors)
DROP TRIGGER IF EXISTS trg_post_purchase_invoice ON purchase_invoices;
CREATE TRIGGER trg_post_purchase_invoice
  BEFORE INSERT OR UPDATE ON purchase_invoices
  FOR EACH ROW EXECUTE FUNCTION post_purchase_invoice_journal();

-- ============================================
-- 6. CREATE CAPITAL CONTRIBUTION JOURNAL TRIGGER
-- ============================================

CREATE OR REPLACE FUNCTION post_capital_contribution_journal()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_je_id UUID;
  v_je_number TEXT;
  v_cash_bank_account_id UUID;
  v_capital_account_id UUID;
BEGIN
  IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND OLD.journal_entry_id IS NULL) THEN
    
    -- Get Cash/Bank account based on contribution type
    IF NEW.contribution_type = 'cash' THEN
      SELECT id INTO v_cash_bank_account_id FROM chart_of_accounts WHERE code = '1101' LIMIT 1;
    ELSIF NEW.bank_account_id IS NOT NULL THEN
      -- Get bank account's COA ID
      SELECT coa_id_idr INTO v_cash_bank_account_id FROM bank_accounts WHERE id = NEW.bank_account_id;
    ELSE
      -- Default to bank account
      SELECT id INTO v_cash_bank_account_id FROM chart_of_accounts WHERE code = '1111' LIMIT 1;
    END IF;

    -- Get director's capital account
    SELECT capital_account_id INTO v_capital_account_id 
    FROM directors WHERE id = NEW.director_id;

    IF v_cash_bank_account_id IS NULL THEN
      RAISE NOTICE 'Cash/Bank account not found';
      RETURN NEW;
    END IF;

    IF v_capital_account_id IS NULL THEN
      -- Use default Owner Capital account if director doesn't have specific one
      SELECT id INTO v_capital_account_id FROM chart_of_accounts WHERE code = '3100' LIMIT 1;
    END IF;

    IF v_capital_account_id IS NULL THEN
      RAISE NOTICE 'Capital account not found for director';
      RETURN NEW;
    END IF;

    -- Generate journal entry number
    v_je_number := 'JE-' || TO_CHAR(NEW.voucher_date, 'YYMM') || '-' || LPAD((
      SELECT COALESCE(MAX(CAST(SUBSTRING(entry_number FROM '(\d+)$') AS INTEGER)), 0) + 1
      FROM journal_entries 
      WHERE entry_number LIKE 'JE-' || TO_CHAR(NEW.voucher_date, 'YYMM') || '-%'
    )::TEXT, 4, '0');

    -- Create journal entry
    INSERT INTO journal_entries (
      entry_number, entry_date, source_module, reference_id, reference_number,
      description, total_debit, total_credit, is_posted, posted_by, created_by
    ) VALUES (
      v_je_number, NEW.voucher_date, 'capital_contribution', NEW.id, NEW.voucher_number,
      'Capital Contribution: ' || NEW.voucher_number || COALESCE(' - ' || NEW.description, ''),
      NEW.amount, NEW.amount, true, NEW.created_by, NEW.created_by
    ) RETURNING id INTO v_je_id;

    -- Debit: Cash/Bank
    INSERT INTO journal_entry_lines (
      journal_entry_id, line_number, account_id, description, debit, credit
    ) VALUES (
      v_je_id, 1, v_cash_bank_account_id, 
      'Capital Contribution - ' || NEW.voucher_number,
      NEW.amount, 0
    );

    -- Credit: Owner Capital
    INSERT INTO journal_entry_lines (
      journal_entry_id, line_number, account_id, description, debit, credit
    ) VALUES (
      v_je_id, 2, v_capital_account_id, 
      'Capital Contribution - ' || NEW.voucher_number,
      0, NEW.amount
    );

    NEW.journal_entry_id := v_je_id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_post_capital_contribution ON capital_contributions;
CREATE TRIGGER trg_post_capital_contribution
  BEFORE INSERT OR UPDATE ON capital_contributions
  FOR EACH ROW EXECUTE FUNCTION post_capital_contribution_journal();

-- ============================================
-- 7. ENABLE RLS ON NEW TABLES
-- ============================================

ALTER TABLE directors ENABLE ROW LEVEL SECURITY;
ALTER TABLE capital_contributions ENABLE ROW LEVEL SECURITY;

-- Directors policies
CREATE POLICY "Authenticated users can view directors" ON directors
  FOR SELECT TO authenticated USING (true);

CREATE POLICY "Admins and accounts can manage directors" ON directors
  FOR ALL TO authenticated 
  USING (
    EXISTS (
      SELECT 1 FROM user_profiles 
      WHERE user_profiles.id = auth.uid() 
      AND user_profiles.role IN ('admin', 'accounts')
    )
  );

-- Capital contributions policies  
CREATE POLICY "Authenticated users can view capital contributions" ON capital_contributions
  FOR SELECT TO authenticated USING (true);

CREATE POLICY "Admins and accounts can manage capital contributions" ON capital_contributions
  FOR ALL TO authenticated 
  USING (
    EXISTS (
      SELECT 1 FROM user_profiles 
      WHERE user_profiles.id = auth.uid() 
      AND user_profiles.role IN ('admin', 'accounts')
    )
  );

-- ============================================
-- MIGRATION COMPLETE
-- ============================================

-- Add comment documenting this migration
COMMENT ON TABLE purchase_invoices IS 'Enhanced purchase invoice system supporting inventory, assets, expenses, and imports with proper journal posting';
COMMENT ON TABLE directors IS 'Directors/Partners for capital contribution tracking (Equity section)';
COMMENT ON TABLE capital_contributions IS 'Capital contributions from directors (Dr Cash/Bank, Cr Owner Capital)';

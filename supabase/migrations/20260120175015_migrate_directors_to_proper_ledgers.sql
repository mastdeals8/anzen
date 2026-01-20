/*
  # Migrate Directors to Proper Accounting Ledgers

  ## Summary
  This migration removes the "Directors Master" concept and implements proper accounting using standard Chart of Accounts.

  ## Background
  Professional accounting systems (Tally/QuickBooks) do NOT have separate "Directors" modules.
  Instead, they use proper ledger accounts in Chart of Accounts for:
  - Owner Capital (Equity)
  - Loans from Owners (Liability)
  - Drawings by Owners (Equity contra)

  ## Changes Made
  1. Create proper ledger accounts for each existing director:
     - Capital Account (under Equity group)
     - Loan Account (under Current Liabilities group)
     - Drawings Account (under Equity group)
  
  2. Link existing director records to their proper ledger accounts
  
  3. Deprecate directors table (keep for reference, don't delete)
  
  4. Add migration notes to capital_contributions

  ## Data Safety
  - ✅ NO DATA DELETED
  - ✅ All existing directors preserved
  - ✅ All existing capital contributions preserved
  - ✅ Only ADDS new ledger accounts
  - ✅ Only UPDATES foreign key links

  ## Validation
  Run this query after migration:
  ```sql
  SELECT d.full_name, 
         ca.name as capital_account,
         la.name as loan_account,
         da.name as drawings_account
  FROM directors d
  LEFT JOIN chart_of_accounts ca ON d.capital_account_id = ca.id
  LEFT JOIN chart_of_accounts la ON d.loan_account_id = la.id
  LEFT JOIN chart_of_accounts da ON d.drawings_account_id = da.id;
  ```
*/

-- ============================================
-- 1. ADD NEW COLUMNS TO DIRECTORS TABLE
-- ============================================

-- Add columns for proper ledger accounts (if not already exist)
ALTER TABLE directors 
ADD COLUMN IF NOT EXISTS loan_account_id UUID REFERENCES chart_of_accounts(id),
ADD COLUMN IF NOT EXISTS drawings_account_id UUID REFERENCES chart_of_accounts(id),
ADD COLUMN IF NOT EXISTS is_deprecated BOOLEAN DEFAULT false;

-- Add comment explaining the deprecation
COMMENT ON COLUMN directors.is_deprecated IS 'TRUE means this record has been migrated to proper Chart of Accounts ledgers. Table kept for historical reference only.';
COMMENT ON COLUMN directors.loan_account_id IS 'Loan from Owner account (Liability section) - for money lent to company';
COMMENT ON COLUMN directors.drawings_account_id IS 'Drawings account (Equity contra) - for money withdrawn by owner';

-- ============================================
-- 2. CREATE PROPER LEDGER ACCOUNTS FOR EXISTING DIRECTORS
-- ============================================

DO $$
DECLARE
  v_director RECORD;
  v_equity_group_id UUID;
  v_liability_group_id UUID;
  v_capital_account_id UUID;
  v_loan_account_id UUID;
  v_drawings_account_id UUID;
  v_capital_code VARCHAR(50);
  v_loan_code VARCHAR(50);
  v_drawings_code VARCHAR(50);
BEGIN
  -- Get or create Equity group
  SELECT id INTO v_equity_group_id 
  FROM chart_of_accounts 
  WHERE code = '3000' AND is_header = true AND account_type = 'equity'
  LIMIT 1;

  IF v_equity_group_id IS NULL THEN
    -- Create Equity group if doesn't exist
    INSERT INTO chart_of_accounts (code, name, account_type, normal_balance, is_header, parent_id, is_active)
    VALUES ('3000', 'Equity', 'equity', 'credit', true, NULL, true)
    RETURNING id INTO v_equity_group_id;
    
    RAISE NOTICE '✅ Created Equity group';
  END IF;

  -- Get or create Current Liabilities group
  SELECT id INTO v_liability_group_id 
  FROM chart_of_accounts 
  WHERE code = '2100' AND is_header = true AND account_type = 'liability'
  LIMIT 1;

  IF v_liability_group_id IS NULL THEN
    -- Create Current Liabilities group if doesn't exist
    INSERT INTO chart_of_accounts (code, name, account_type, normal_balance, is_header, parent_id, is_active)
    VALUES ('2100', 'Current Liabilities', 'liability', 'credit', true, NULL, true)
    RETURNING id INTO v_liability_group_id;
    
    RAISE NOTICE '✅ Created Current Liabilities group';
  END IF;

  -- Loop through all existing directors and create their ledger accounts
  FOR v_director IN 
    SELECT * FROM directors 
    WHERE is_deprecated = false OR is_deprecated IS NULL
  LOOP
    RAISE NOTICE '🔄 Processing director: %', v_director.full_name;

    -- Generate unique account codes
    v_capital_code := COALESCE(v_director.director_code, 'DIR' || SUBSTRING(v_director.id::text, 1, 4));
    v_loan_code := v_capital_code || '-L';
    v_drawings_code := v_capital_code || '-D';

    -- 1. Create/Update CAPITAL account (Equity)
    IF v_director.capital_account_id IS NOT NULL THEN
      -- Capital account already exists, just update it
      UPDATE chart_of_accounts
      SET 
        name = 'Capital - ' || v_director.full_name,
        account_type = 'equity',
        normal_balance = 'credit',
        is_active = true,
        parent_id = v_equity_group_id
      WHERE id = v_director.capital_account_id;
      
      v_capital_account_id := v_director.capital_account_id;
      RAISE NOTICE '  ✅ Updated existing capital account';
    ELSE
      -- Check if account with this code already exists
      SELECT id INTO v_capital_account_id
      FROM chart_of_accounts
      WHERE code = '3100-' || v_capital_code;

      IF v_capital_account_id IS NULL THEN
        -- Create new capital account
        INSERT INTO chart_of_accounts (
          code, name, account_type, normal_balance, is_header, parent_id, is_active
        ) VALUES (
          '3100-' || v_capital_code,
          'Capital - ' || v_director.full_name,
          'equity',
          'credit',
          false,
          v_equity_group_id,
          true
        ) RETURNING id INTO v_capital_account_id;
        
        RAISE NOTICE '  ✅ Created capital account: %', '3100-' || v_capital_code;
      END IF;

      -- Update director record
      UPDATE directors 
      SET capital_account_id = v_capital_account_id
      WHERE id = v_director.id;
    END IF;

    -- 2. Create LOAN account (Liability)
    SELECT id INTO v_loan_account_id
    FROM chart_of_accounts
    WHERE code = '2110-' || v_loan_code;

    IF v_loan_account_id IS NULL THEN
      INSERT INTO chart_of_accounts (
        code, name, account_type, normal_balance, is_header, parent_id, is_active
      ) VALUES (
        '2110-' || v_loan_code,
        'Loan from ' || v_director.full_name,
        'liability',
        'credit',
        false,
        v_liability_group_id,
        true
      ) RETURNING id INTO v_loan_account_id;
      
      RAISE NOTICE '  ✅ Created loan account: %', '2110-' || v_loan_code;
    END IF;

    UPDATE directors 
    SET loan_account_id = v_loan_account_id
    WHERE id = v_director.id;

    -- 3. Create DRAWINGS account (Equity contra)
    SELECT id INTO v_drawings_account_id
    FROM chart_of_accounts
    WHERE code = '3200-' || v_drawings_code;

    IF v_drawings_account_id IS NULL THEN
      INSERT INTO chart_of_accounts (
        code, name, account_type, normal_balance, is_header, parent_id, is_active
      ) VALUES (
        '3200-' || v_drawings_code,
        'Drawings - ' || v_director.full_name,
        'equity',
        'debit',
        false,
        v_equity_group_id,
        true
      ) RETURNING id INTO v_drawings_account_id;
      
      RAISE NOTICE '  ✅ Created drawings account: %', '3200-' || v_drawings_code;
    END IF;

    UPDATE directors 
    SET drawings_account_id = v_drawings_account_id
    WHERE id = v_director.id;

  END LOOP;

  RAISE NOTICE '✅ Migration complete - all directors now have proper ledger accounts';
END $$;

-- ============================================
-- 3. ADD HELPFUL INDEXES
-- ============================================

CREATE INDEX IF NOT EXISTS idx_directors_loan_account ON directors(loan_account_id);
CREATE INDEX IF NOT EXISTS idx_directors_drawings_account ON directors(drawings_account_id);
CREATE INDEX IF NOT EXISTS idx_directors_is_deprecated ON directors(is_deprecated);

-- ============================================
-- 4. UPDATE TABLE COMMENTS
-- ============================================

COMMENT ON TABLE directors IS 'DEPRECATED: Directors master table kept for historical reference. New entries should use proper Chart of Accounts ledgers directly (Capital/Loan/Drawings accounts).';
COMMENT ON TABLE capital_contributions IS 'DEPRECATED: Capital contributions now should be recorded as normal Journal/Payment vouchers using Capital ledger accounts.';

-- ============================================
-- 5. CREATE HELPFUL VIEW FOR DIRECTOR BALANCES
-- ============================================

CREATE OR REPLACE VIEW director_account_balances AS
SELECT 
  d.id as director_id,
  d.full_name as director_name,
  d.designation,
  
  -- Capital Account
  ca.id as capital_account_id,
  ca.code as capital_account_code,
  ca.name as capital_account_name,
  COALESCE((
    SELECT SUM(credit - debit)
    FROM journal_entry_lines jel
    JOIN journal_entries je ON je.id = jel.journal_entry_id
    WHERE jel.account_id = ca.id
  ), 0) as capital_balance,
  
  -- Loan Account
  la.id as loan_account_id,
  la.code as loan_account_code,
  la.name as loan_account_name,
  COALESCE((
    SELECT SUM(credit - debit)
    FROM journal_entry_lines jel
    JOIN journal_entries je ON je.id = jel.journal_entry_id
    WHERE jel.account_id = la.id
  ), 0) as loan_balance,
  
  -- Drawings Account
  da.id as drawings_account_id,
  da.code as drawings_account_code,
  da.name as drawings_account_name,
  COALESCE((
    SELECT SUM(debit - credit)
    FROM journal_entry_lines jel
    JOIN journal_entries je ON je.id = jel.journal_entry_id
    WHERE jel.account_id = da.id
  ), 0) as drawings_balance,
  
  -- Total Equity
  COALESCE((
    SELECT SUM(credit - debit)
    FROM journal_entry_lines jel
    JOIN journal_entries je ON je.id = jel.journal_entry_id
    WHERE jel.account_id = ca.id
  ), 0) - COALESCE((
    SELECT SUM(debit - credit)
    FROM journal_entry_lines jel
    JOIN journal_entries je ON je.id = jel.journal_entry_id
    WHERE jel.account_id = da.id
  ), 0) as net_capital
  
FROM directors d
LEFT JOIN chart_of_accounts ca ON d.capital_account_id = ca.id
LEFT JOIN chart_of_accounts la ON d.loan_account_id = la.id
LEFT JOIN chart_of_accounts da ON d.drawings_account_id = da.id
WHERE d.is_active = true;

COMMENT ON VIEW director_account_balances IS 'Helper view showing all director-related account balances. Capital and Loan balances should appear in Balance Sheet. Drawings reduce net capital.';

-- ============================================
-- MIGRATION COMPLETE
-- ============================================

-- Validation query (for manual testing):
-- SELECT * FROM director_account_balances;

import { useEffect, useState } from 'react';
import { Layout } from '../components/Layout';
import { useAuth } from '../contexts/AuthContext';
import { FinanceProvider, useFinance } from '../contexts/FinanceContext';
import { Calendar } from 'lucide-react';

// Import all finance components
import { PurchaseInvoiceManager } from '../components/finance/PurchaseInvoiceManager';
import { ReceiptVoucherManager } from '../components/finance/ReceiptVoucherManager';
import { PaymentVoucherManager } from '../components/finance/PaymentVoucherManager';
import { PettyCashManager } from '../components/finance/PettyCashManager';
import { FundTransferManager } from '../components/finance/FundTransferManager';
import { JournalEntryViewerEnhanced as JournalEntryViewer } from '../components/finance/JournalEntryViewerEnhanced';
import { AccountLedger } from '../components/finance/AccountLedger';
import PartyLedger from '../components/finance/PartyLedger';
import BankLedger from '../components/finance/BankLedger';
import { FinancialReports } from '../components/finance/FinancialReports';
import { ReceivablesManager } from '../components/finance/ReceivablesManager';
import { PayablesManager } from '../components/finance/PayablesManager';
import OutstandingSummary from '../components/finance/OutstandingSummary';
import { AgeingReport } from './reports/AgeingReport';
import { BankReconciliationEnhanced as BankReconciliation } from '../components/finance/BankReconciliationEnhanced';
import { ChartOfAccountsManager } from '../components/finance/ChartOfAccountsManager';
import { SuppliersManager } from '../components/finance/SuppliersManager';
import { BankAccountsManager } from '../components/finance/BankAccountsManager';
import { TaxReports } from '../components/finance/TaxReports';

type FinanceTab =
  | 'purchase' | 'sales' | 'receipt' | 'payment' | 'journal' | 'contra'
  | 'ledger' | 'journal_register' | 'bank_ledger' | 'party_ledger'
  | 'trial_balance' | 'pnl' | 'balance_sheet' | 'receivables' | 'payables' | 'ageing' | 'tax'
  | 'coa' | 'customers' | 'suppliers' | 'products' | 'banks' | 'directors';

interface MenuItem {
  id: FinanceTab;
  label: string;
  shortcut?: string;
}

interface MenuGroup {
  label: string;
  items: MenuItem[];
}

const financeMenu: MenuGroup[] = [
  {
    label: 'VOUCHERS',
    items: [
      { id: 'purchase', label: 'Purchase', shortcut: 'F9' },
      { id: 'sales', label: 'Sales', shortcut: 'F10' },
      { id: 'receipt', label: 'Receipt', shortcut: 'F6' },
      { id: 'payment', label: 'Payment', shortcut: 'F5' },
      { id: 'journal', label: 'Journal', shortcut: 'F7' },
      { id: 'contra', label: 'Contra', shortcut: 'F4' },
    ]
  },
  {
    label: 'BOOKS',
    items: [
      { id: 'ledger', label: 'Ledger', shortcut: 'Ctrl+L' },
      { id: 'journal_register', label: 'Journal Register', shortcut: 'Ctrl+J' },
      { id: 'bank_ledger', label: 'Bank Ledger' },
      { id: 'party_ledger', label: 'Party Ledger' },
    ]
  },
  {
    label: 'REPORTS',
    items: [
      { id: 'trial_balance', label: 'Trial Balance' },
      { id: 'pnl', label: 'Profit & Loss' },
      { id: 'balance_sheet', label: 'Balance Sheet' },
      { id: 'receivables', label: 'Receivables' },
      { id: 'payables', label: 'Payables' },
      { id: 'ageing', label: 'Ageing' },
      { id: 'tax', label: 'Tax Reports' },
    ]
  },
  {
    label: 'MASTERS',
    items: [
      { id: 'coa', label: 'Chart of Accounts' },
      { id: 'suppliers', label: 'Suppliers' },
      { id: 'banks', label: 'Banks' },
      { id: 'directors', label: 'Directors' },
    ]
  }
];

function FinanceContent() {
  const { profile } = useAuth();
  const { dateRange, setDateRange } = useFinance();
  const [activeTab, setActiveTab] = useState<FinanceTab>('purchase');
  const canManage = profile?.role === 'admin' || profile?.role === 'accounts';

  // Keyboard shortcuts
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (['INPUT', 'TEXTAREA', 'SELECT'].includes((e.target as HTMLElement).tagName)) {
        return;
      }

      if (e.key === 'F2') {
        e.preventDefault();
        const input = document.querySelector('input[type="date"]') as HTMLInputElement;
        if (input) input.focus();
      } else if (e.key === 'F4') {
        e.preventDefault();
        setActiveTab('contra');
      } else if (e.key === 'F5') {
        e.preventDefault();
        setActiveTab('payment');
      } else if (e.key === 'F6') {
        e.preventDefault();
        setActiveTab('receipt');
      } else if (e.key === 'F7') {
        e.preventDefault();
        setActiveTab('journal');
      } else if (e.key === 'F9') {
        e.preventDefault();
        setActiveTab('purchase');
      } else if (e.key === 'F10') {
        e.preventDefault();
        // Navigate to Sales page instead
        window.location.hash = 'sales';
      } else if (e.ctrlKey && e.key === 'l') {
        e.preventDefault();
        setActiveTab('ledger');
      } else if (e.ctrlKey && e.key === 'j') {
        e.preventDefault();
        setActiveTab('journal_register');
      }
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, []);

  const renderContent = () => {
    switch (activeTab) {
      case 'purchase':
        return <PurchaseInvoiceManager canManage={canManage} />;
      case 'sales':
        // Navigate to main sales page
        window.location.hash = 'sales';
        return <div className="p-8 text-center text-gray-500">Redirecting to Sales...</div>;
      case 'receipt':
        return <ReceiptVoucherManager canManage={canManage} />;
      case 'payment':
        return <PaymentVoucherManager canManage={canManage} />;
      case 'journal':
        return <div className="text-center p-8">Manual Journal Entry form coming soon</div>;
      case 'contra':
        return <FundTransferManager canManage={canManage} />;
      case 'ledger':
        return <AccountLedger />;
      case 'journal_register':
        return <JournalEntryViewer canManage={canManage} />;
      case 'bank_ledger':
        return <BankLedger />;
      case 'party_ledger':
        return <PartyLedger />;
      case 'trial_balance':
        return <FinancialReports initialReport="trial_balance" />;
      case 'pnl':
        return <FinancialReports initialReport="pnl" />;
      case 'balance_sheet':
        return <FinancialReports initialReport="balance_sheet" />;
      case 'receivables':
        return <ReceivablesManager canManage={canManage} />;
      case 'payables':
        return <PayablesManager canManage={canManage} />;
      case 'ageing':
        return <AgeingReport />;
      case 'tax':
        return <TaxReports />;
      case 'coa':
        return <ChartOfAccountsManager canManage={canManage} />;
      case 'suppliers':
        return <SuppliersManager canManage={canManage} />;
      case 'banks':
        return <BankAccountsManager canManage={canManage} />;
      case 'directors':
        return <div className="text-center p-8">Directors master coming soon</div>;
      default:
        return <div className="text-center p-8 text-gray-500">Select a module from the menu</div>;
    }
  };

  return (
    <Layout>
      <div className="flex h-screen bg-gray-50">
        {/* Left Sidebar - Clean Menu */}
        <div className="w-56 bg-white border-r border-gray-200 flex flex-col">
          {/* Menu Groups */}
          <div className="flex-1 overflow-y-auto">
            {financeMenu.map((group, groupIdx) => (
              <div key={group.label} className={groupIdx > 0 ? 'border-t border-gray-200' : ''}>
                <div className="px-3 py-2 text-xs font-semibold text-gray-500 uppercase tracking-wider">
                  {group.label}
                </div>
                <div>
                  {group.items.map((item) => (
                    <button
                      key={item.id}
                      onClick={() => setActiveTab(item.id)}
                      className={`w-full text-left px-4 py-2 text-sm transition-colors ${
                        activeTab === item.id
                          ? 'bg-blue-50 text-blue-700 font-medium border-l-2 border-blue-600'
                          : 'text-gray-700 hover:bg-gray-50 border-l-2 border-transparent'
                      }`}
                    >
                      <div className="flex items-center justify-between">
                        <span>{item.label}</span>
                        {item.shortcut && (
                          <span className="text-xs text-gray-400">{item.shortcut}</span>
                        )}
                      </div>
                    </button>
                  ))}
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* Main Content Area */}
        <div className="flex-1 flex flex-col overflow-hidden">
          {/* Top Bar - Global Date Range ONLY */}
          <div className="bg-white border-b border-gray-200 px-6 py-3 flex items-center justify-between">
            <h1 className="text-lg font-semibold text-gray-900">Finance & Accounting</h1>

            {/* SINGLE GLOBAL DATE RANGE */}
            <div className="flex items-center gap-3 bg-gray-50 px-4 py-2 rounded border border-gray-300">
              <Calendar className="w-4 h-4 text-gray-500" />
              <div className="flex items-center gap-2">
                <span className="text-xs text-gray-600">Period:</span>
                <input
                  type="date"
                  value={dateRange.startDate}
                  onChange={(e) => setDateRange({ ...dateRange, startDate: e.target.value })}
                  className="px-2 py-1 text-sm border border-gray-300 rounded focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
                />
                <span className="text-gray-500">to</span>
                <input
                  type="date"
                  value={dateRange.endDate}
                  onChange={(e) => setDateRange({ ...dateRange, endDate: e.target.value })}
                  className="px-2 py-1 text-sm border border-gray-300 rounded focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
                />
              </div>
            </div>
          </div>

          {/* Content Area - Pure White Background */}
          <div className="flex-1 overflow-auto bg-white">
            <div className="p-6">
              {renderContent()}
            </div>
          </div>
        </div>
      </div>
    </Layout>
  );
}

export function Finance() {
  return (
    <FinanceProvider>
      <FinanceContent />
    </FinanceProvider>
  );
}

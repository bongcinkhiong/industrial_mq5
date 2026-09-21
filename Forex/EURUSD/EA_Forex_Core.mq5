//+------------------------------------------------------------------+
//|                                               EA_Forex_Core.mq5  |
//|               Mean Reversion Strategy (BB + RSI) for Forex       |
//+------------------------------------------------------------------+
#property copyright "Forex Strategy EA"
#property version   "1.02"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- INPUT PARAMETERS ---
input group "=== Indicator Parameters ==="
input int      InpBands_Period    = 20;     // Bollinger Bands Period
input double   InpBands_Dev       = 2.0;    // Bollinger Bands Deviation
input int      InpRSI_Period      = 14;     // RSI Period
input double   InpRSI_Overbought  = 70.0;   // RSI Overbought Level
input double   InpRSI_Oversold    = 30.0;   // RSI Oversold Level

input group "=== Risk Management (1:1 Leverage / $100k Deposit) ==="
input double   InpMaxMarginUse    = 85.0;   // Max Free Margin Usage (%)
input int      InpStopLossPips    = 35;     // Stop Loss in Pips (0 = Disable)
input int      InpTakeProfitPips  = 50;     // Take Profit in Pips (0 = Disable)
input double   InpMaxDrawdown     = 30.0;   // Max Drawdown Killswitch (%)

//--- GLOBAL VARIABLES ---
int      handleBB;
int      handleRSI;
ulong    expertMagic = 992026;
double   initialBalance;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(expertMagic);
   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   // Inisialisasi Indicator Handles
   handleBB = iBands(_Symbol, _Period, InpBands_Period, 0, InpBands_Dev, PRICE_CLOSE);
   handleRSI = iRSI(_Symbol, _Period, InpRSI_Period, PRICE_CLOSE);

   if(handleBB == INVALID_HANDLE || handleRSI == INVALID_HANDLE)
   {
      Print("Error: Gagal menginisialisasi indikator BB/RSI.");
      return(INIT_FAILED);
   }

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleBB);
   IndicatorRelease(handleRSI);
}

//+------------------------------------------------------------------+
//| Calculate Safe Lot Size for 1:1 Leverage                         |
//+------------------------------------------------------------------+
double CalculateSafeLot()
{
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   // Hitung kebutuhan margin per 1.0 Lot pada leverage 1:1
   double marginForOneLot = 0;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 1.0, ask, marginForOneLot) || marginForOneLot <= 0)
   {
      marginForOneLot = ask * 100000.0; // Fallback calculation
   }

   // Gunakan maksimal 85% Free Margin agar tidak terkena Margin Call
   double usableMargin = freeMargin * (InpMaxMarginUse / 100.0);
   double calculatedLot = usableMargin / marginForOneLot;

   // Normalisasi ukuran Lot sesuai aturan Broker
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   calculatedLot = MathFloor(calculatedLot / lotStep) * lotStep;

   if(calculatedLot < minLot) calculatedLot = minLot;
   if(calculatedLot > maxLot) calculatedLot = maxLot;

   return calculatedLot;
}

//+------------------------------------------------------------------+
//| Check Equity Killswitch (Max Drawdown 30%)                       |
//+------------------------------------------------------------------+
bool IsKillswitchActive()
{
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double currentDrawdown = ((initialBalance - currentEquity) / initialBalance) * 100.0;
   
   if(currentDrawdown >= InpMaxDrawdown)
   {
      Print("KILLSWITCH AKTIF! Drawdown telah mencapai ", DoubleToString(currentDrawdown, 2), "%. Trading dihentikan.");
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Jika kena killswitch 30% DD, hentikan transaksi baru
   if(IsKillswitchActive()) return;

   // Filter: Hanya izinkan 1 posisi aktif dalam 1 waktu (Single Position Mean Reversion)
   if(PositionsTotal() > 0) return;

   // Ambil Data Indikator (Bar 1 = Bar yang baru close)
   double bbUpper[], bbLower[], bbMiddle[], rsi[];
   ArraySetAsSeries(bbUpper, true);
   ArraySetAsSeries(bbLower, true);
   ArraySetAsSeries(bbMiddle, true);
   ArraySetAsSeries(rsi, true);

   if(CopyBuffer(handleBB, 1, 1, 2, bbUpper) <= 0 ||
      CopyBuffer(handleBB, 2, 1, 2, bbLower) <= 0 ||
      CopyBuffer(handleBB, 0, 1, 2, bbMiddle) <= 0 ||
      CopyBuffer(handleRSI, 0, 1, 2, rsi) <= 0)
   {
      return;
   }

   double closePrice1 = iClose(_Symbol, _Period, 1);
   double safeLot = CalculateSafeLot();

   // Poin multiplier untuk SL/TP dalam Pips
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pipMult = (digits == 3 || digits == 5) ? 10.0 : 1.0;

   // --- LOGIK ENTRY BUY (Harga Tembus Lower Band + RSI Oversold) ---
   if(closePrice1 < bbLower[0] && rsi[0] < InpRSI_Oversold)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl = (InpStopLossPips > 0) ? ask - (InpStopLossPips * point * pipMult) : 0;
      double tp = (InpTakeProfitPips > 0) ? ask + (InpTakeProfitPips * point * pipMult) : 0;

      trade.Buy(safeLot, _Symbol, ask, sl, tp, "BUY Mean Reversion");
   }

   // --- LOGIK ENTRY SELL (Harga Tembus Upper Band + RSI Overbought) ---
   if(closePrice1 > bbUpper[0] && rsi[0] > InpRSI_Overbought)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl = (InpStopLossPips > 0) ? bid + (InpStopLossPips * point * pipMult) : 0;
      double tp = (InpTakeProfitPips > 0) ? bid - (InpTakeProfitPips * point * pipMult) : 0;

      trade.Sell(safeLot, _Symbol, bid, sl, tp, "SELL Mean Reversion");
   }
}
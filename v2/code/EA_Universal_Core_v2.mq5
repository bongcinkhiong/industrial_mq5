//+------------------------------------------------------------------+
//|                                           EA_Universal_Core_v3.mq5|
//|            Mean Reversion BB + RSI, ATR-based, No Martingale/Grid|
//|   Satu kode untuk semua instrumen (Forex, Logam, Indeks, Crypto, |
//|   Energi). Tidak ada nilai points tetap, semua dinormalisasi ATR.|
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, UGM CS Student"
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- Bollinger Bands
input group "=== Bollinger Bands ==="
input int      InpBB_Period     = 20;       // BB Period
input double   InpBB_Dev        = 2.0;      // BB Deviation

//--- RSI + sinyal
input group "=== RSI & Sinyal ==="
input int      InpRSI_Period    = 14;       // RSI Period
input double   InpRSI_OS        = 30.0;     // RSI Oversold
input double   InpRSI_OB        = 70.0;     // RSI Overbought
input int      InpLookback      = 3;        // Jendela bar untuk sinyal (>=1)

//--- Filter tren
input group "=== Trend Filter ==="
input bool             InpUseTrend  = true;       // Pakai filter EMA
input ENUM_TIMEFRAMES  InpTrendTF   = PERIOD_H4;  // Timeframe EMA tren
input int              InpEMA_Period= 200;        // Periode EMA

//--- SL/TP/Exit berbasis ATR
input group "=== ATR SL / TP / Exit ==="
input int      InpATR_Period    = 14;       // ATR Period
input double   InpSL_ATR        = 2.5;      // SL = ATR x ini
input double   InpTP_ATR        = 3.0;      // TP = ATR x ini (0 = tanpa TP)
input bool     InpExitAtMid     = true;     // Exit saat harga balik ke middle band
input int      InpMaxBars       = 48;       // Time stop dalam bar (0 = off)

//--- Risk
input group "=== Risk & Money Management ==="
input double   InpRiskPercent   = 1.0;      // Risiko per trade (% equity)
input double   InpMaxNotionalX  = 1.0;      // Batas nilai posisi / equity (1.0 = no leverage)
input double   InpMaxSpreadATR  = 0.15;     // Skip entry jika spread > ATR x ini
input double   InpMaxDD_Percent = 25.0;     // Stop trading jika DD dari puncak >= ini
input int      InpPauseDays     = 10;       // Lama jeda setelah DD guard aktif
input ulong    InpMagic         = 20261010; // Magic number

//--- Handle & state
int       h_bb, h_rsi, h_atr, h_ema;
datetime  last_bar_time = 0;
double    peak_equity   = 0;
datetime  paused_until  = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpLookback < 1) { Print("InpLookback harus >= 1"); return INIT_PARAMETERS_INCORRECT; }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(50);

   h_bb  = iBands(_Symbol, _Period, InpBB_Period, 0, InpBB_Dev, PRICE_CLOSE);
   h_rsi = iRSI(_Symbol, _Period, InpRSI_Period, PRICE_CLOSE);
   h_atr = iATR(_Symbol, _Period, InpATR_Period);
   h_ema = INVALID_HANDLE;
   if(InpUseTrend)
      h_ema = iMA(_Symbol, InpTrendTF, InpEMA_Period, 0, MODE_EMA, PRICE_CLOSE);

   if(h_bb == INVALID_HANDLE || h_rsi == INVALID_HANDLE || h_atr == INVALID_HANDLE ||
      (InpUseTrend && h_ema == INVALID_HANDLE))
   {
      Print("Gagal membuat handle indikator.");
      return INIT_FAILED;
   }

   peak_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(h_bb);
   IndicatorRelease(h_rsi);
   IndicatorRelease(h_atr);
   if(h_ema != INVALID_HANDLE) IndicatorRelease(h_ema);
}

//+------------------------------------------------------------------+
//| Cari posisi milik EA ini (simbol + magic)                        |
//+------------------------------------------------------------------+
bool GetMyPosition(ulong &ticket, long &type, datetime &open_time)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      ticket    = t;
      type      = PositionGetInteger(POSITION_TYPE);
      open_time = (datetime)PositionGetInteger(POSITION_TIME);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Hitung lot: min(lot berbasis risiko, lot batas notional)         |
//+------------------------------------------------------------------+
double CalcLots(bool is_buy, double price, double sl_dist)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   ENUM_ORDER_TYPE ot = is_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double sl_price = is_buy ? price - sl_dist : price + sl_dist;

   double profit = 0;
   if(!OrderCalcProfit(ot, _Symbol, 1.0, price, sl_price, profit)) return 0;
   double loss_per_lot = -profit;
   if(loss_per_lot <= 0) return 0;

   double lot_risk = equity * InpRiskPercent / 100.0 / loss_per_lot;
   double lots = lot_risk;

   // Batas notional (no leverage): margin x leverage akun = nilai posisi per 1 lot
   double margin = 0;
   if(OrderCalcMargin(ot, _Symbol, 1.0, price, margin) && margin > 0)
   {
      double lev = (double)AccountInfoInteger(ACCOUNT_LEVERAGE);
      double notional_per_lot = margin * lev;
      double lot_cap = equity * InpMaxNotionalX / notional_per_lot;
      lots = MathMin(lots, lot_cap);
   }

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0) return 0;

   lots = MathFloor(lots / step) * step;
   if(lots < minv) return 0;          // modal/risiko terlalu kecil untuk lot minimum
   lots = MathMin(lots, maxv);
   return NormalizeDouble(lots, 8);
}

//+------------------------------------------------------------------+
void OnTick()
{
   // Jalan sekali per bar baru
   datetime bar_time = iTime(_Symbol, _Period, 0);
   if(bar_time == last_bar_time) return;
   last_bar_time = bar_time;

   //--- DD guard
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(paused_until > 0 && TimeCurrent() >= paused_until)
   {
      paused_until = 0;
      peak_equity  = equity;
   }
   if(equity > peak_equity) peak_equity = equity;
   double dd = (peak_equity > 0) ? (peak_equity - equity) / peak_equity * 100.0 : 0;

   ulong ticket = 0; long ptype = 0; datetime popen = 0;
   bool has_pos = GetMyPosition(ticket, ptype, popen);

   if(paused_until == 0 && dd >= InpMaxDD_Percent)
   {
      if(has_pos) trade.PositionClose(ticket);
      paused_until = TimeCurrent() + (datetime)InpPauseDays * 86400;
      return;
   }
   if(paused_until > 0) return;

   //--- Ambil data (bar 1 = bar tertutup terakhir)
   int need = InpLookback + 1;
   double upper[], lower[], mid[], rsi[], atr[], cls[];
   ArraySetAsSeries(upper, true); ArraySetAsSeries(lower, true);
   ArraySetAsSeries(mid,   true); ArraySetAsSeries(rsi,   true);
   ArraySetAsSeries(atr,   true); ArraySetAsSeries(cls,   true);

   if(CopyBuffer(h_bb, 1, 1, need, upper) < need) return;   // upper band
   if(CopyBuffer(h_bb, 2, 1, need, lower) < need) return;   // lower band
   if(CopyBuffer(h_bb, 0, 1, need, mid)   < need) return;   // middle band
   if(CopyBuffer(h_rsi, 0, 1, need, rsi)  < need) return;
   if(CopyBuffer(h_atr, 0, 1, 1, atr)     < 1)    return;
   if(CopyClose(_Symbol, _Period, 1, need, cls) < need) return;
   if(atr[0] <= 0) return;

   //--- Kelola posisi terbuka
   if(has_pos)
   {
      bool do_exit = false;
      if(InpExitAtMid)
      {
         if(ptype == POSITION_TYPE_BUY  && cls[0] >= mid[0]) do_exit = true;
         if(ptype == POSITION_TYPE_SELL && cls[0] <= mid[0]) do_exit = true;
      }
      if(InpMaxBars > 0)
      {
         long bars_held = (long)((TimeCurrent() - popen) / PeriodSeconds(_Period));
         if(bars_held >= InpMaxBars) do_exit = true;
      }
      if(do_exit) trade.PositionClose(ticket);
      return;   // satu posisi saja, tanpa tambah posisi
   }

   //--- Filter spread
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return;
   if((ask - bid) > InpMaxSpreadATR * atr[0]) return;

   //--- Filter tren
   bool trend_up = true, trend_dn = true;
   if(InpUseTrend)
   {
      double ema[];
      ArraySetAsSeries(ema, true);
      if(CopyBuffer(h_ema, 0, 1, 1, ema) < 1) return;
      trend_up = (cls[0] > ema[0]);
      trend_dn = (cls[0] < ema[0]);
   }

   //--- Sinyal: sentuh band dalam jendela + RSI keluar dari zona ekstrem
   bool touched_low = false, touched_high = false;
   for(int i = 0; i < InpLookback; i++)
   {
      if(cls[i] <= lower[i]) touched_low  = true;
      if(cls[i] >= upper[i]) touched_high = true;
   }
   double min_rsi = 100.0, max_rsi = 0.0;
   for(int i = 1; i <= InpLookback; i++)
   {
      min_rsi = MathMin(min_rsi, rsi[i]);
      max_rsi = MathMax(max_rsi, rsi[i]);
   }

   bool buy_sig  = touched_low  && rsi[0] > InpRSI_OS && min_rsi <= InpRSI_OS
                   && cls[0] < mid[0] && trend_up;
   bool sell_sig = touched_high && rsi[0] < InpRSI_OB && max_rsi >= InpRSI_OB
                   && cls[0] > mid[0] && trend_dn;

   if(!buy_sig && !sell_sig) return;

   //--- Eksekusi
   bool   is_buy  = buy_sig;
   double price   = is_buy ? ask : bid;
   double sl_dist = atr[0] * InpSL_ATR;

   double stops_level = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(sl_dist <= stops_level) return;

   double sl = is_buy ? price - sl_dist : price + sl_dist;
   double tp = 0;
   if(InpTP_ATR > 0)
   {
      double tp_dist = atr[0] * InpTP_ATR;
      if(tp_dist > stops_level)
         tp = is_buy ? price + tp_dist : price - tp_dist;
   }
   sl = NormalizeDouble(sl, _Digits);
   if(tp > 0) tp = NormalizeDouble(tp, _Digits);

   double lots = CalcLots(is_buy, price, sl_dist);
   if(lots <= 0) return;

   if(is_buy) trade.Buy(lots,  _Symbol, 0, sl, tp, "EA_v3_Buy");
   else       trade.Sell(lots, _Symbol, 0, sl, tp, "EA_v3_Sell");
}
//+------------------------------------------------------------------+
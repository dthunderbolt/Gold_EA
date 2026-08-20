//+------------------------------------------------------------------+
//|                                  Gold_Session_Breakout_EA_v1.mq5 |
//|                                  Copyright 2026, Quantitative FX |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "1.00"

#include <Trade\Trade.mqh>
CTrade trade;

// --- Institutional Inputs ---
input int      AsianStartHour_GMT = 0;       // Asian Session Start (GMT)
input int      AsianEndHour_GMT   = 7;       // Asian Session End (GMT)
input double   EntryBuffer        = 0.50;    // Breakout entry buffer ($)
input double   RiskPercent        = 2.0;     // Total Equity Risk Per Trade (%)
input double   MaxAllowedSpread   = 0.35;    // Max spread allowed for entries ($)
input int      AtrPeriod          = 14;      // Volatility lookback bars

// --- Internal Engine State ---
double   asianHigh = -1.0;
double   asianLow = 999999.0;
bool     ordersPlacedToday = false;
datetime lastOrderDay = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("Gold Session Breakout EA successfully initiated.");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("EA shut down or removed from chart.");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   string symbol = _Symbol;
   datetime localTime = TimeCurrent();
   datetime gmtTime   = TimeGMT();
   
   // Extract precise calendar structures
   MqlDateTime dt;
   TimeToStruct(localTime, dt);
   
   // --- Fix #4: Friday Weekend Exposure Liquidation Guard ---
   if(dt.day_of_week == 5 && dt.hour >= 20)
   {
      PurgeAllOrdersAndPositions(symbol);
      ordersPlacedToday = false;
      return;
   }
   
   // Dynamic GMT Server-Sync Engine
   int gmtOffsetHours = (int)MathRound((double)(localTime - gmtTime) / 3600.0);
   int serverStartHour = AsianStartHour_GMT + gmtOffsetHours;
   int serverEndHour   = AsianEndHour_GMT + gmtOffsetHours;

   // Reset order flag at midnight server time
   if(dt.hour == 0 && dt.min == 0)
   {
      ordersPlacedToday = false;
   }

   // --- State 1: Active Order/Position Tracking Loop (Fix #2 Multi-Fill Guard) ---
   int totalPositions = PositionsTotal();
   int totalOrders = OrdersTotal();
   
   if(totalPositions > 0 && totalOrders > 0)
   {
      // If a trade has filled, immediately delete the counter pending stop order
      for(int i = totalOrders - 1; i >= 0; i--)
      {
         ulong orderTicket = OrderGetTicket(i);
         if(OrderGetString(ORDER_SYMBOL) == symbol)
         {
            trade.OrderDelete(orderTicket);
            Print("Breakout detected. Safely purged counter pending order.");
         }
      }
   }

   // --- State 2: Range Isolation & Order Deployment Window ---
   if(!ordersPlacedToday && dt.hour == serverEndHour && dt.min == 45)
   {
      // Protect execution from Spread Poisoning
      double liveSpread = SymbolInfoDouble(symbol, SYMBOL_ASK) - SymbolInfoDouble(symbol, SYMBOL_BID);
      if(liveSpread > MaxAllowedSpread) return; // Wait for next tick if spread is spiked

      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      int copied = CopyRates(symbol, PERIOD_M15, 0, 40, rates);
      if(copied <= 0) return;

      asianHigh = -1.0;
      asianLow = 999999.0;

      for(int i=0; i<copied; i++)
      {
         MqlDateTime barTime;
         TimeToStruct(rates[i].time, barTime);
         if(barTime.day == dt.day && barTime.hour >= serverStartHour && barTime.hour <= serverEndHour)
         {
            if(rates[i].high > asianHigh) asianHigh = rates[i].high;
            if(rates[i].low < asianLow)   asianLow = rates[i].low;
         }
      }

      if(asianHigh == -1.0 || asianLow == 999999.0) return;

      // Volatility Sizing Analysis
      int atrHandle = iATR(symbol, PERIOD_M15, AtrPeriod);
      double atrValues[];
      ArraySetAsSeries(atrValues, true);
      CopyBuffer(atrHandle, 0, 0, 1, atrValues);
      double currentAtr = atrValues[0];
      
      double slDistance = NormalizeDouble(currentAtr * 1.5, _Digits);
      if(slDistance < 2.50) slDistance = 2.50; // Dynamic safety floor ($2.50 minimum stop)
      double tpDistance = slDistance * 2.0;

      // Dynamic Lot Sizing Compounding Engine (Fix #3 Step Floor Guard)
      double accountEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      double cashRisk = accountEquity * (RiskPercent / 100.0);
      
      double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
      double pointsDistance = slDistance / tickSize;
      
      double rawLotSize = cashRisk / (pointsDistance * tickValue);
      double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
      
      double dynamicLot = MathFloor(rawLotSize / lotStep) * lotStep;
      dynamicLot = MathMax(SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN), MathMin(SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX), dynamicLot));
      dynamicLot = NormalizeDouble(dynamicLot, 2);

      // Final Price Vector Coordinates
      double buyStopPrice  = NormalizeDouble(asianHigh + EntryBuffer, _Digits);
      double sellStopPrice = NormalizeDouble(asianLow - EntryBuffer, _Digits);
      
      double buySL  = NormalizeDouble(buyStopPrice - slDistance, _Digits);
      double buyTP  = NormalizeDouble(buyStopPrice + tpDistance, _Digits);
      double sellSL = NormalizeDouble(sellStopPrice + slDistance, _Digits);
      double sellTP = NormalizeDouble(sellStopPrice - tpDistance, _Digits);
      
      // Limit Slippage
      trade.SetDeviationInPoints(25); 
      
      // Execute Orders into the market
      if(trade.BuyStop(dynamicLot, buyStopPrice, symbol, buySL, buyTP, ORDER_TIME_DAY) &&
         trade.SellStop(dynamicLot, sellStopPrice, symbol, sellSL, sellTP, ORDER_TIME_DAY))
      {
         ordersPlacedToday = true;
         PrintFormat("Autonomous EA Orders Placed. Lots: %.2f | Risk: $%.2f", dynamicLot, cashRisk);
      }
   }
}

//+------------------------------------------------------------------+
//| Structural cleanup engine for weekend safety                     |
//+------------------------------------------------------------------+
void PurgeAllOrdersAndPositions(string symbol)
{
   // Wipe pending orders
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(OrderGetString(ORDER_SYMBOL) == symbol) trade.OrderDelete(ticket);
   }
   // Close active positions
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) == symbol) trade.PositionClose(ticket);
   }
}

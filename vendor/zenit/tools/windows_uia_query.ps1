# UI Automation client in the guest worker, separate from the App.
function Initialize-WindowsUiaClient {
  if (-not ('ZenitUiaQuery' -as [type])) {
    Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,WindowsBase
    Add-Type -ReferencedAssemblies UIAutomationClient,UIAutomationTypes,WindowsBase @'
using System;
using System.Collections.Generic;
using System.Threading;
using System.Windows.Automation;
using System.Windows.Automation.Text;
public static class ZenitUiaQuery {
  public static void Invoke(IntPtr hwnd, int pid, string name) {
    Exception error=null;
    Thread thread=new Thread(delegate() {
      try {
        AutomationElement root=AutomationElement.FromHandle(hwnd);
        if(root==null || root.Current.ProcessId!=pid) throw new InvalidOperationException("UIA root owner mismatch");
        var matches=root.FindAll(TreeScope.Descendants,new AndCondition(
          new PropertyCondition(AutomationElement.NameProperty,name),
          new PropertyCondition(AutomationElement.FrameworkIdProperty,"Zenit")));
        if(matches.Count!=1) throw new InvalidOperationException("UIA action needs exactly one owned named control: "+matches.Count);
        object pattern;
        if(!matches[0].TryGetCurrentPattern(InvokePattern.Pattern,out pattern)) throw new InvalidOperationException("Control has no Invoke pattern");
        using(var invoked=new ManualResetEvent(false)) {
          AutomationEventHandler handler=delegate(object sender,AutomationEventArgs args) {
            try { invoked.Set(); } catch(ObjectDisposedException) { /* Late event during unregister. */ }
          };
          Automation.AddAutomationEventHandler(InvokePattern.InvokedEvent,matches[0],TreeScope.Element,handler);
          try {
            ((InvokePattern)pattern).Invoke();
            if(!invoked.WaitOne(5000)) throw new TimeoutException("UIA Invoked event was not delivered");
          } finally { Automation.RemoveAutomationEventHandler(InvokePattern.InvokedEvent,matches[0],handler); }
        }
      } catch(Exception exception) { error=exception; }
    });
    thread.IsBackground=true; thread.SetApartmentState(ApartmentState.MTA); thread.Start();
    if(!thread.Join(12000)) throw new TimeoutException("UIA MTA Invoke timed out");
    if(error!=null) throw new InvalidOperationException("UIA Invoke failed: "+error.Message,error);
  }
  public static int[] Toggle(IntPtr hwnd, int pid, string name) {
    int[] result=null; Exception error=null;
    Thread thread=new Thread(delegate() {
      try {
        AutomationElement root=AutomationElement.FromHandle(hwnd);
        if(root==null || root.Current.ProcessId!=pid) throw new InvalidOperationException("UIA root owner mismatch");
        var matches=root.FindAll(TreeScope.Descendants,new AndCondition(
          new PropertyCondition(AutomationElement.NameProperty,name),
          new PropertyCondition(AutomationElement.FrameworkIdProperty,"Zenit")));
        if(matches.Count!=1) throw new InvalidOperationException("UIA action needs exactly one owned named control: "+matches.Count);
        object pattern;
        if(!matches[0].TryGetCurrentPattern(TogglePattern.Pattern,out pattern)) throw new InvalidOperationException("Control has no Toggle pattern");
        var toggle=(TogglePattern)pattern;
        int before=(int)toggle.Current.ToggleState, eventState=-1;
        using(var changed=new ManualResetEvent(false)) {
          AutomationPropertyChangedEventHandler handler=delegate(object sender,AutomationPropertyChangedEventArgs args) {
            try {
              Interlocked.Exchange(ref eventState,Convert.ToInt32(args.NewValue));
              changed.Set();
            } catch(ObjectDisposedException) { /* Late event during unregister. */ }
          };
          Automation.AddAutomationPropertyChangedEventHandler(matches[0],TreeScope.Element,handler,TogglePattern.ToggleStateProperty);
          try {
            toggle.Toggle();
            if(!changed.WaitOne(5000)) throw new TimeoutException("UIA ToggleState property event was not delivered");
            int after=(int)toggle.Current.ToggleState;
            if(after==before || after!=eventState) throw new InvalidOperationException("UIA ToggleState publication/event disagree");
            result=new int[]{before,after,eventState};
          } finally { Automation.RemoveAutomationPropertyChangedEventHandler(matches[0],handler); }
        }
      } catch(Exception exception) { error=exception; }
    });
    thread.IsBackground=true; thread.SetApartmentState(ApartmentState.MTA); thread.Start();
    if(!thread.Join(12000)) throw new TimeoutException("UIA MTA Toggle timed out");
    if(error!=null) throw new InvalidOperationException("UIA Toggle failed: "+error.Message,error);
    return result;
  }
  public static Dictionary<string,object> TextAction(IntPtr hwnd, int pid, string name, string operation, string value) {
    Exception error=null; Dictionary<string,object> result=null;
    Thread thread=new Thread(delegate() {
      try {
        AutomationElement root=AutomationElement.FromHandle(hwnd);
        if(root==null || root.Current.ProcessId!=pid) throw new InvalidOperationException("UIA root owner mismatch");
        var matches=root.FindAll(TreeScope.Descendants,new AndCondition(
          new PropertyCondition(AutomationElement.NameProperty,name),
          new PropertyCondition(AutomationElement.FrameworkIdProperty,"Zenit")));
        if(matches.Count!=1) throw new InvalidOperationException("Text action needs exactly one owned control");
        var element=matches[0];
        var pattern=(TextPattern)element.GetCurrentPattern(TextPattern.Pattern);
        string before=pattern.DocumentRange.GetText(65536);
        string eventDocument=null, eventSelection=null; Exception callbackError=null;
        using(var textChanged=new ManualResetEvent(false))
        using(var selectionChanged=new ManualResetEvent(false)) {
          AutomationEventHandler textHandler=delegate(object sender,AutomationEventArgs args) {
            try { eventDocument=pattern.DocumentRange.GetText(65536); }
            catch(Exception exception) { callbackError=exception; }
            try { textChanged.Set(); } catch(ObjectDisposedException) { }
          };
          AutomationEventHandler selectionHandler=delegate(object sender,AutomationEventArgs args) {
            try {
              var selected=pattern.GetSelection();
              if(selected.Length!=1) throw new InvalidOperationException("Text event requires one selection");
              eventSelection=selected[0].GetText(65536);
            } catch(Exception exception) { callbackError=exception; }
            try { selectionChanged.Set(); } catch(ObjectDisposedException) { }
          };
          Automation.AddAutomationEventHandler(TextPattern.TextChangedEvent,element,TreeScope.Element,textHandler);
          try {
            Automation.AddAutomationEventHandler(TextPattern.TextSelectionChangedEvent,element,TreeScope.Element,selectionHandler);
            try {
              if(operation=="value") {
                if(before==value) throw new InvalidOperationException("Text event write must change value");
                ((ValuePattern)element.GetCurrentPattern(ValuePattern.Pattern)).SetValue(value);
                if(!textChanged.WaitOne(5000)) throw new TimeoutException("TextChanged event missing");
                if(eventDocument!=value) throw new InvalidOperationException("TextChanged callback read stale document");
              } else {
                var range=pattern.DocumentRange;
                if(operation=="caret-end") range.MoveEndpointByRange(TextPatternRangeEndpoint.Start,range,TextPatternRangeEndpoint.End);
                else if(operation!="select-all") throw new InvalidOperationException("Unknown text operation");
                range.Select();
                if(!selectionChanged.WaitOne(5000)) throw new TimeoutException("TextSelectionChanged event missing");
                if(eventSelection!=(operation=="select-all" ? before : "")) throw new InvalidOperationException("Selection callback read stale range");
              }
              if(callbackError!=null) throw callbackError;
              var selection=pattern.GetSelection();
              result=new Dictionary<string,object>{{"document",pattern.DocumentRange.GetText(65536)},
                {"selection",selection[0].GetText(65536)},{"event_document",eventDocument},{"event_selection",eventSelection},
                {"text_event",textChanged.WaitOne(0)},{"selection_event",selectionChanged.WaitOne(0)}};
            } finally { Automation.RemoveAutomationEventHandler(TextPattern.TextSelectionChangedEvent,element,selectionHandler); }
          } finally { Automation.RemoveAutomationEventHandler(TextPattern.TextChangedEvent,element,textHandler); }
        }
      } catch(Exception exception) { error=exception; }
    });
    thread.IsBackground=true; thread.SetApartmentState(ApartmentState.MTA); thread.Start();
    if(!thread.Join(12000)) throw new TimeoutException("UIA MTA text action timed out");
    if(error!=null) throw new InvalidOperationException("UIA text action failed: "+error.Message,error);
    return result;
  }
  public static bool SetValue(IntPtr hwnd, int pid, string name, string text) {
    Exception error=null; bool changedEvent=false;
    Thread thread=new Thread(delegate() {
      try {
        AutomationElement root=AutomationElement.FromHandle(hwnd);
        if(root==null || root.Current.ProcessId!=pid) throw new InvalidOperationException("UIA root owner mismatch");
        var matches=root.FindAll(TreeScope.Descendants,new AndCondition(
          new PropertyCondition(AutomationElement.NameProperty,name),
          new PropertyCondition(AutomationElement.FrameworkIdProperty,"Zenit")));
        if(matches.Count!=1) throw new InvalidOperationException("UIA action needs exactly one owned named control: "+matches.Count);
        object pattern;
        if(!matches[0].TryGetCurrentPattern(ValuePattern.Pattern,out pattern)) throw new InvalidOperationException("Control has no Value pattern");
        var value=(ValuePattern)pattern;
        // Still call the native provider for readonly/disabled controls to prove refusal.
        if(matches[0].Current.IsPassword) { value.SetValue(text); return; }
        string before=value.Current.Value, eventValue=null;
        using(var changed=new ManualResetEvent(false)) {
          AutomationPropertyChangedEventHandler handler=delegate(object sender,AutomationPropertyChangedEventArgs args) {
            try { eventValue=args.NewValue as string; changed.Set(); } catch(ObjectDisposedException) { }
          };
          Automation.AddAutomationPropertyChangedEventHandler(matches[0],TreeScope.Element,handler,ValuePattern.ValueProperty);
          try {
            value.SetValue(text);
            if(before!=text) {
              if(!changed.WaitOne(5000)) throw new TimeoutException("UIA Value property event was not delivered");
              if(value.Current.Value!=text || eventValue!=text) throw new InvalidOperationException("UIA Value publication/event disagree");
              changedEvent=true;
            }
          } finally { Automation.RemoveAutomationPropertyChangedEventHandler(matches[0],handler); }
        }
      } catch(Exception exception) { error=exception; }
    });
    thread.IsBackground=true; thread.SetApartmentState(ApartmentState.MTA); thread.Start();
    if(!thread.Join(12000)) throw new TimeoutException("UIA MTA SetValue timed out");
    if(error!=null) throw new InvalidOperationException("UIA SetValue failed: "+error.Message,error);
    return changedEvent;
  }
  public static double[] SetRange(IntPtr hwnd, int pid, string selector, bool byId, double number) {
    double[] result=null; Exception error=null;
    Thread thread=new Thread(delegate() {
      try {
        AutomationElement root=AutomationElement.FromHandle(hwnd);
        if(root==null || root.Current.ProcessId!=pid) throw new InvalidOperationException("UIA root owner mismatch");
        var matches=root.FindAll(TreeScope.Descendants,new AndCondition(
          new PropertyCondition(byId ? AutomationElement.AutomationIdProperty : AutomationElement.NameProperty,selector),
          new PropertyCondition(AutomationElement.FrameworkIdProperty,"Zenit")));
        if(matches.Count!=1) throw new InvalidOperationException("UIA action needs exactly one owned control: "+matches.Count);
        object pattern;
        if(!matches[0].TryGetCurrentPattern(RangeValuePattern.Pattern,out pattern)) throw new InvalidOperationException("Control has no RangeValue pattern");
        var range=(RangeValuePattern)pattern;
        double before=range.Current.Value, eventValue=double.NaN;
        using(var changed=new ManualResetEvent(false)) {
          AutomationPropertyChangedEventHandler handler=delegate(object sender,AutomationPropertyChangedEventArgs args) {
            try { eventValue=Convert.ToDouble(args.NewValue); changed.Set(); } catch(ObjectDisposedException) { }
          };
          Automation.AddAutomationPropertyChangedEventHandler(matches[0],TreeScope.Element,handler,RangeValuePattern.ValueProperty);
          try {
            range.SetValue(number);
            if(!changed.WaitOne(5000)) throw new TimeoutException("UIA RangeValue event was not delivered");
            double after=range.Current.Value;
            if(after==before || after!=eventValue) throw new InvalidOperationException("UIA RangeValue publication/event disagree");
            result=new double[]{before,after,eventValue};
          } finally { Automation.RemoveAutomationPropertyChangedEventHandler(matches[0],handler); }
        }
      } catch(Exception exception) { error=exception; }
    });
    thread.IsBackground=true; thread.SetApartmentState(ApartmentState.MTA); thread.Start();
    if(!thread.Join(12000)) throw new TimeoutException("UIA MTA RangeValue timed out");
    if(error!=null) throw new InvalidOperationException("UIA RangeValue failed: "+error.Message,error);
    return result;
  }
  public static void Select(IntPtr hwnd, int pid, string name, bool byId, string operation) {
    Exception error=null;
    Thread thread=new Thread(delegate() {
      try {
        AutomationElement root=AutomationElement.FromHandle(hwnd);
        if(root==null || root.Current.ProcessId!=pid) throw new InvalidOperationException("UIA root owner mismatch");
        var matches=root.FindAll(TreeScope.Descendants,new AndCondition(
          new PropertyCondition(byId ? AutomationElement.AutomationIdProperty : AutomationElement.NameProperty,name),new PropertyCondition(AutomationElement.FrameworkIdProperty,"Zenit")));
        if(matches.Count!=1) throw new InvalidOperationException("Selection needs exactly one owned control");
        var item=(SelectionItemPattern)matches[0].GetCurrentPattern(SelectionItemPattern.Pattern);
        var group=(SelectionPattern)item.Current.SelectionContainer.GetCurrentPattern(SelectionPattern.Pattern);
        var previous=group.Current.GetSelection(); bool wasSelected=item.Current.IsSelected;
        int expectedCount=operation=="select" ? 1 : operation=="add" ? previous.Length+(wasSelected?0:1) : previous.Length-(wasSelected?1:0);
        bool mustChange=operation=="select" ? !wasSelected || previous.Length!=1 : operation=="add" ? !wasSelected : wasSelected;
        var eventType=operation=="remove" ? SelectionItemPattern.ElementRemovedFromSelectionEvent : expectedCount==1 ? SelectionItemPattern.ElementSelectedEvent : SelectionItemPattern.ElementAddedToSelectionEvent;
        var oldItems=new List<AutomationElement>(); var oldFlags=new List<ManualResetEvent>(); var oldHandlers=new List<AutomationEventHandler>();
        using(var changed=new ManualResetEvent(false)) {
          AutomationEventHandler handler=delegate(object sender,AutomationEventArgs args) { try { changed.Set(); } catch(ObjectDisposedException) {} };
          Automation.AddAutomationEventHandler(eventType,matches[0],TreeScope.Element,handler);
          try {
            if(operation=="select") foreach(var old in previous) {
              if(old.Current.AutomationId==matches[0].Current.AutomationId) continue;
              var flag=new ManualResetEvent(false);
              AutomationEventHandler removed=delegate(object sender,AutomationEventArgs args) { try { flag.Set(); } catch(ObjectDisposedException) {} };
              Automation.AddAutomationEventHandler(SelectionItemPattern.ElementRemovedFromSelectionEvent,old,TreeScope.Element,removed);
              oldItems.Add(old); oldFlags.Add(flag); oldHandlers.Add(removed);
            }
            var deadline=DateTime.UtcNow.AddSeconds(5);
            if(operation=="select") item.Select(); else if(operation=="add") item.AddToSelection(); else if(operation=="remove") item.RemoveFromSelection(); else throw new InvalidOperationException("Unknown Selection operation");
            if(mustChange && !changed.WaitOne(Math.Max(0,(int)(deadline-DateTime.UtcNow).TotalMilliseconds))) throw new TimeoutException("Selection event not delivered");
            foreach(var flag in oldFlags) if(!flag.WaitOne(Math.Max(0,(int)(deadline-DateTime.UtcNow).TotalMilliseconds))) throw new TimeoutException("Removed selection event not delivered");
            if(item.Current.IsSelected!=(operation!="remove") || group.Current.GetSelection().Length!=expectedCount) throw new InvalidOperationException("Selection not committed");
          } finally {
            Automation.RemoveAutomationEventHandler(eventType,matches[0],handler);
            for(int i=0;i<oldItems.Count;i++) { Automation.RemoveAutomationEventHandler(SelectionItemPattern.ElementRemovedFromSelectionEvent,oldItems[i],oldHandlers[i]); oldFlags[i].Dispose(); }
          }
        }
      } catch(Exception exception) { error=exception; }
    });
    thread.IsBackground=true; thread.SetApartmentState(ApartmentState.MTA); thread.Start();
    if(!thread.Join(12000)) throw new TimeoutException("UIA MTA Selection timed out");
    if(error!=null) throw new InvalidOperationException("UIA Selection failed: "+error.Message,error);
  }
  public static void Expand(IntPtr hwnd, int pid, string selector, bool byId, bool expanded) {
    Exception error=null;
    Thread thread=new Thread(delegate() {
      try {
        AutomationElement root=AutomationElement.FromHandle(hwnd);
        if(root==null || root.Current.ProcessId!=pid) throw new InvalidOperationException("UIA root owner mismatch");
        var matches=root.FindAll(TreeScope.Descendants,new AndCondition(
          new PropertyCondition(byId ? AutomationElement.AutomationIdProperty : AutomationElement.NameProperty,selector),
          new PropertyCondition(AutomationElement.FrameworkIdProperty,"Zenit")));
        if(matches.Count!=1) throw new InvalidOperationException("Expansion needs exactly one owned control");
        var pattern=(ExpandCollapsePattern)matches[0].GetCurrentPattern(ExpandCollapsePattern.Pattern);
        var expected=expanded ? ExpandCollapseState.Expanded : ExpandCollapseState.Collapsed;
        bool mustChange=pattern.Current.ExpandCollapseState!=expected;
        using(var changed=new ManualResetEvent(false)) {
          AutomationPropertyChangedEventHandler handler=delegate(object sender,AutomationPropertyChangedEventArgs args) {
            if(Convert.ToInt32(args.NewValue)==(int)expected) { try { changed.Set(); } catch(ObjectDisposedException) { } }
          };
          Automation.AddAutomationPropertyChangedEventHandler(matches[0],TreeScope.Element,handler,ExpandCollapsePattern.ExpandCollapseStateProperty);
          try {
            if(expanded) pattern.Expand(); else pattern.Collapse();
            if(mustChange && !changed.WaitOne(5000)) throw new TimeoutException("ExpandCollapse event not delivered");
            if(pattern.Current.ExpandCollapseState!=expected) throw new InvalidOperationException("Expansion not committed");
          } finally { Automation.RemoveAutomationPropertyChangedEventHandler(matches[0],handler); }
        }
      } catch(Exception exception) { error=exception; }
    });
    thread.IsBackground=true; thread.SetApartmentState(ApartmentState.MTA); thread.Start();
    if(!thread.Join(12000)) throw new TimeoutException("UIA MTA ExpandCollapse timed out");
    if(error!=null) throw new InvalidOperationException("UIA ExpandCollapse failed: "+error.Message,error);
  }
  public static object[] Read(IntPtr hwnd, int pid) {
    object[] result=null; Exception error=null;
    Thread thread=new Thread(delegate() {
      try {
        // A whole-tree walk races the app's published snapshots: an element can
        // vanish between GetFirstChild and the next property read, as for any
        // UIA client. Retry the walk from the root, as real clients re-query.
        for(int attempt=0;;attempt++) { try {
        AutomationElement root=AutomationElement.FromHandle(hwnd);
        if(root==null || root.Current.ProcessId!=pid) throw new InvalidOperationException("UIA root owner mismatch");
        var output=new List<object>();
        var pending=new Queue<AutomationElement>(); pending.Enqueue(root);
        while(pending.Count>0) {
          if(output.Count>=4352) throw new InvalidOperationException("UIA query tree limit exceeded");
          AutomationElement element=pending.Dequeue();
          var info=element.Current; var rect=info.BoundingRectangle;
          object toggle; int? toggleState=null;
          bool toggleAvailable=element.TryGetCurrentPattern(TogglePattern.Pattern,out toggle);
          if(toggleAvailable) toggleState=(int)((TogglePattern)toggle).Current.ToggleState;
          object value; string currentValue=null; bool? valueReadonly=null; bool valueDenied=false;
          bool valueAvailable=element.TryGetCurrentPattern(ValuePattern.Pattern,out value);
          if(valueAvailable) {
            valueReadonly=((ValuePattern)value).Current.IsReadOnly;
            try { currentValue=((ValuePattern)value).Current.Value; }
            catch(Exception) { if(!info.IsPassword) throw; valueDenied=true; }
          }
          object selectionItem, selection; object itemInfo=null, selectionInfo=null;
          if(element.TryGetCurrentPattern(SelectionItemPattern.Pattern,out selectionItem)) {
            var current=((SelectionItemPattern)selectionItem).Current;
            itemInfo=new Dictionary<string,object>{{"selected",current.IsSelected},{"container",current.SelectionContainer.Current.AutomationId}};
          }
          if(element.TryGetCurrentPattern(SelectionPattern.Pattern,out selection)) {
            var current=((SelectionPattern)selection).Current; var ids=new List<string>();
            foreach(var selected in current.GetSelection()) ids.Add(selected.Current.AutomationId);
            selectionInfo=new Dictionary<string,object>{{"multiple",current.CanSelectMultiple},{"required",current.IsSelectionRequired},{"ids",ids.ToArray()}};
          }
          object range; object rangeInfo=null;
          bool rangeAvailable=element.TryGetCurrentPattern(RangeValuePattern.Pattern,out range);
          if(rangeAvailable) {
            var current=((RangeValuePattern)range).Current;
            rangeInfo=new Dictionary<string,object>{{"value",current.Value},{"min",current.Minimum},{"max",current.Maximum},
              {"readonly",current.IsReadOnly},{"small",double.IsNaN(current.SmallChange) ? (object)null : current.SmallChange},
              {"large",double.IsNaN(current.LargeChange) ? (object)null : current.LargeChange}};
          }
          object textObject; object textInfo=null;
          bool textAvailable=element.TryGetCurrentPattern(TextPattern.Pattern,out textObject);
          bool textProperty=(bool)element.GetCurrentPropertyValue(AutomationElement.IsTextPatternAvailableProperty);
          if(textAvailable) {
            var textPattern=(TextPattern)textObject;
            string document=textPattern.DocumentRange.GetText(65536);
            var selectedText=new List<string>();
            foreach(var selected in textPattern.GetSelection()) selectedText.Add(selected.GetText(65536));
            var visibleText=new List<string>(); bool visibleUnknown=false; bool? pointEmpty=null;
            try {
              foreach(var visible in textPattern.GetVisibleRanges()) {
                visibleText.Add(visible.GetText(65536));
                var rectangles=visible.GetBoundingRectangles();
                if(pointEmpty==null && rectangles.Length>0 && rectangles[0].Width>0 && rectangles[0].Height>0) {
                  var point=textPattern.RangeFromPoint(new System.Windows.Point(rectangles[0].X+rectangles[0].Width*.5,rectangles[0].Y+rectangles[0].Height*.5));
                  pointEmpty=point.GetText(1)=="";
                }
              }
            } catch(NotSupportedException) { visibleUnknown=true; }
            textInfo=new Dictionary<string,object>{{"document",document},{"length",document.Length},
              {"selection",selectedText.ToArray()},{"visible",visibleText.ToArray()},{"visible_unknown",visibleUnknown},
              {"supported_selection",(int)textPattern.SupportedTextSelection},{"point_empty",pointEmpty}};
          }
          object expansion;
          output.Add(new Dictionary<string,object> {
            {"name",info.Name},{"framework",info.FrameworkId},{"role",info.ControlType.Id},
            {"text_available",textAvailable},{"text_property",textProperty},{"text",textInfo},
            {"automation_id",info.AutomationId},{"enabled",info.IsEnabled},
            {"password",info.IsPassword},{"focusable",info.IsKeyboardFocusable},
            {"focused",info.HasKeyboardFocus},{"offscreen",info.IsOffscreen},
            {"expand_available",element.TryGetCurrentPattern(ExpandCollapsePattern.Pattern,out expansion)},
            {"expand_state",expansion==null ? -1 : (int)((ExpandCollapsePattern)expansion).Current.ExpandCollapseState},
            {"selection_item",itemInfo},{"selection",selectionInfo},
            {"range_available",rangeAvailable},{"range",rangeInfo},
            {"value_available",valueAvailable},{"value",currentValue},{"value_readonly",valueReadonly},{"value_read_denied",valueDenied},
            {"toggle_available",toggleAvailable},{"toggle_state",toggleState},
            {"invoke_available",(bool)element.GetCurrentPropertyValue(AutomationElement.IsInvokePatternAvailableProperty)},
            {"x",rect.IsEmpty ? 0 : rect.X},{"y",rect.IsEmpty ? 0 : rect.Y},
            {"width",rect.IsEmpty ? 0 : rect.Width},{"height",rect.IsEmpty ? 0 : rect.Height},
            {"runtime_id",element.GetRuntimeId()}
          });
          AutomationElement child=TreeWalker.RawViewWalker.GetFirstChild(element);
          while(child!=null) {
            if(pending.Count>=4352) throw new InvalidOperationException("UIA query child limit exceeded");
            pending.Enqueue(child); child=TreeWalker.RawViewWalker.GetNextSibling(child);
          }
        }
        result=output.ToArray();
        break;
        } catch(ElementNotAvailableException) { if(attempt>=4) throw; Thread.Sleep(20); } }
      } catch(Exception exception) { error=exception; }
    });
    thread.IsBackground=true; thread.SetApartmentState(ApartmentState.MTA); thread.Start();
    if(!thread.Join(12000)) throw new TimeoutException("UIA MTA query timed out");
    if(error!=null) throw new InvalidOperationException("UIA query failed",error);
    return result;
  }
}
'@
  }
}
function Get-WindowsUiaTree($proc) {
  Initialize-WindowsUiaClient
  $status=Get-WindowsNativeStatus $proc
  $nodes=[ZenitUiaQuery]::Read([IntPtr]::new([long]$status.hwnd),$proc.Id)
  return @{ok=$true; nodes=@($nodes); hwnd=$status.hwnd; foreground_hwnd=[ZenitNativeInput]::GetForegroundWindow().ToInt64()}
}
function Invoke-WindowsUiaControl($proc, $body) {
  $byId=$body.action -in @('uia-set-range','uia-select','uia-expand') -and $null -ne $body.PSObject.Properties['automation_id']
  $name=if ($byId) { [string]$body.automation_id } else { [string]$body.name }
  if ($name.Length -lt 1 -or $name.Length -gt 128 -or $name.IndexOf([char]0) -ge 0) { throw 'Invalid UIA control name' }
  Initialize-WindowsUiaClient
  $status=Get-WindowsNativeStatus $proc
  if ($body.action -eq 'uia-text-action') {
    $operation=[string]$body.operation
    if ($operation -notin @('value','select-all','caret-end')) { throw 'Invalid UIA text operation' }
    if ($operation -eq 'value' -and ($body.value -isnot [string] -or $body.value.Length -gt 16384 -or $body.value.IndexOf([char]0) -ge 0)) { throw 'Invalid UIA text value' }
    $result=[ZenitUiaQuery]::TextAction([IntPtr]::new([long]$status.hwnd),$proc.Id,$name,$operation,[string]$body.value)
    return @{ok=$true; text=$result; foreground_hwnd=[ZenitNativeInput]::GetForegroundWindow().ToInt64()}
  }
  if ($body.action -eq 'uia-expand') {
    if ($body.expanded -isnot [bool]) { throw 'Invalid expansion state' }
    [ZenitUiaQuery]::Expand([IntPtr]::new([long]$status.hwnd),$proc.Id,$name,$byId,[bool]$body.expanded)
    return @{ok=$true; expansion_committed=$true; foreground_hwnd=[ZenitNativeInput]::GetForegroundWindow().ToInt64()}
  }
  if ($body.action -eq 'uia-select') {
    $operation=[string]$body.operation
    if ($operation -notin @('select','add','remove')) { throw 'Invalid UIA Selection operation' }
    [ZenitUiaQuery]::Select([IntPtr]::new([long]$status.hwnd),$proc.Id,$name,$byId,$operation)
    return @{ok=$true; selection_accepted=$true; selection_committed=$true; foreground_hwnd=[ZenitNativeInput]::GetForegroundWindow().ToInt64()}
  }
  if ($body.action -eq 'uia-set-range') {
    if ($null -eq $body.PSObject.Properties['value'] -or $body.value -isnot [ValueType] -or $body.value -is [bool]) { throw 'Invalid UIA numeric value' }
    $number=[double]$body.value
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { throw 'Invalid UIA numeric value' }
    $states=[ZenitUiaQuery]::SetRange([IntPtr]::new([long]$status.hwnd),$proc.Id,$name,$byId,$number)
    return @{ok=$true; before_value=$states[0]; after_value=$states[1]; event_value=$states[2]; range_event=$true; foreground_hwnd=[ZenitNativeInput]::GetForegroundWindow().ToInt64()}
  }
  if ($body.action -eq 'uia-set-value') {
    if ($null -eq $body.PSObject.Properties['value'] -or $body.value -isnot [string] -or $body.value.Length -gt 16384 -or $body.value.IndexOf([char]0) -ge 0) { throw 'Invalid UIA text value' }
    $changed=[ZenitUiaQuery]::SetValue([IntPtr]::new([long]$status.hwnd),$proc.Id,$name,[string]$body.value)
    return @{ok=$true; name=$name; value_event=$changed; foreground_hwnd=[ZenitNativeInput]::GetForegroundWindow().ToInt64()}
  }
  if ($body.action -eq 'uia-toggle') {
    $states=[ZenitUiaQuery]::Toggle([IntPtr]::new([long]$status.hwnd),$proc.Id,$name)
    return @{ok=$true; name=$name; before_state=$states[0]; after_state=$states[1]; event_state=$states[2]; toggle_event=$true; foreground_hwnd=[ZenitNativeInput]::GetForegroundWindow().ToInt64()}
  }
  [ZenitUiaQuery]::Invoke([IntPtr]::new([long]$status.hwnd),$proc.Id,$name)
  return @{ok=$true; name=$name; invoked_event=$true; foreground_hwnd=[ZenitNativeInput]::GetForegroundWindow().ToInt64()}
}

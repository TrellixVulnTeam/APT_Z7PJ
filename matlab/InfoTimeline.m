classdef InfoTimeline < handle

  properties (Constant)
    TLPROPFILESTR = 'landmark_features.yaml';
    TLPROPTYPES = {'Labels','Predictions','Imported'};
  end
   
  properties (SetAccess=private)
    TLPROPS; % struct array, features we can compute. Initted from yaml at construction-time
    TLPROPS_TRACKER; % struct array, features for current tracker. Initted at setTracker time
  end
  
%   % AL: Not using transparency for now due to perf issues on Linux
%   properties (Constant)
%     SELECTALPHA = 0.5;
%   end
  properties
    lObj % scalar Labeler handle
    hAx % scalar handle to timeline axis
    hAxL = [] % scalar handle to timeline axis
    hCurrFrame % scalar line handle current frame
    hCurrFrameL = []% scalar line handle current frame
    hStatThresh % scalar line handle, threshold
    hCMenuClearAll % scalar context menu
    hCMenuClearBout % scalar context menu

    hZoom % zoom handle for hAx
    hPan % pan handle "

    hPts % [npts] line handles
    hPtStat % scalar line handle
    npts % number of label points in current movie/timeline
    %nfrm % number of frames "
    tldata % [nptsxnfrm] most recent data set/shown in setLabelsFull. this is NOT y-normalized
    hPtsL % [npts] line handles
    
    listeners % [nlistener] col cell array of labeler prop listeners
    listenersTracker % col cell array of tracker listeners

    tracker % scalar LabelTracker obj
    
    color = [1,1,1]; % color when there is only one statistic for all landmarks
  end
  properties (SetObservable)
    props % [nprop]. struct array of timeline-viewable property specs. Applicable when proptype is not 'Predictions'
    props_tracker % [ntrkprop]. ". Applicable when proptype is 'Predictions'
    curprop % row index into props, or props_tracker, depending on curproptype.
    proptypes % property types, eg 'Labels' or 'Predictions'.    
    curproptype % row index into proptypes
  end
  properties
    jumpThreshold
    jumpCondition
  end
  
  %% Select
  properties (SetAccess=private)
    hSelIm % scalar image handle for selection
    selectOnStartFrm 
    isinit
  end
  properties (SetObservable)
    selectOn % scalar logical, if true, select "Pen" is down
  end
  
  %% GT/highlighting
  properties 
    hSegLineGT % scalar SegmentedLine
    hSegLineGTLbled % scalar SegmentedLine
  end
  
  %%
  properties (Dependent)
    prefs % projPrefs.InfoTimelines preferences substruct
    nfrm
  end
    
  methods
    function set.selectOn(obj,v)
      obj.selectOn = v;
      if ~obj.isinit %#ok<MCSUP>
        if v        
          obj.selectOnStartFrm = obj.lObj.currFrame; %#ok<MCSUP>
          obj.hCurrFrame.LineWidth = 3; %#ok<MCSUP>
          if obj.isL,
            obj.hCurrFrameL.LineWidth = 3; %#ok<MCSUP>
          end
        else
          obj.selectOnStartFrm = []; %#ok<MCSUP>
          obj.hCurrFrame.LineWidth = 0.5; %#ok<MCSUP>
          if obj.isL,
            obj.hCurrFrameL.LineWidth = 0.5; %#ok<MCSUP>
          end
          obj.setLabelerSelectedFrames();
        end
      end
    end
    function v = get.prefs(obj)
      v = obj.lObj.projPrefs.InfoTimelines;
    end
    function v = get.nfrm(obj)
      lblObj = obj.lObj;
      if lblObj.hasMovie
        v = lblObj.nframes;
      else
        v = 1;
      end
    end
  end
  
  methods
    
    function obj = InfoTimeline(labeler,ax,axl)
      
      if nargin < 3,
        axl = [];
      end
      
      obj.lObj = labeler;
      ax.Color = [0 0 0];
      ax.ButtonDownFcn = @(src,evt)obj.cbkBDF(src,evt);
      hold(ax,'on');
      obj.hAx = ax;
      obj.hCurrFrame = plot(ax,[nan nan],[0 1],'-','Color',[1 1 1],...
        'hittest','off','Tag','InfoTimeline_CurrFrame');
      obj.hStatThresh = plot(ax,[nan nan],[0 0],'-','Color',[1 1 1],...
        'hittest','off','visible','off','Tag','InfoTimeline_StatThresh');
      
%       obj.hMarked = plot(ax,[nan nan],[nan nan],'-','Color',[1 1 0],'hittest','off');

      if ~isempty(axl) && ishandle(axl),
        axl.Color = [0 0 0];
        axl.ButtonDownFcn = @(src,evt)obj.cbkBDF(src,evt);
        hold(axl,'on');
      end
      obj.hAxL = axl;
      
      if obj.isL,
        obj.hCurrFrameL = plot(axl,[nan nan],[0 1],'-','Color',[1 1 1],'hittest','off','Tag','InfoTimeline_CurrFrameLabel');
      else
        obj.hCurrFrameL = [];
      end

      fig = ax.Parent;
      hZ = zoom(fig);
      setAxesZoomMotion(hZ,ax,'vertical');
      obj.hZoom = hZ;
      hZ.ActionPostCallback = @(src,evt) obj.cbkPostZoom(src,evt);
      hP = pan(fig);
      setAxesPanMotion(hP,ax,'vertical');
      obj.hPan = hP;
      hP.ActionPostCallback = @(src,evt) obj.cbkPostZoom(src,evt);

      if obj.isL,
        setAxesZoomMotion(hZ,axl,'horizontal');
        setAxesPanMotion(hP,axl,'horizontal');
      end
      
      obj.hPts = [];
      obj.hPtStat = [];
      obj.hPtsL = [];
      obj.npts = nan;
      %Rxobj.nfrm = nan;
            
      listeners = cell(0,1);
%       listeners{end+1,1} = addlistener(labeler,...
%         {'labeledpos','labeledposMarked','labeledpostag','labeledposGT',...
%          'labeledpostagGT'},... 
%         'PostSet',@obj.cbkLabelUpdated);
      
      listeners{end+1,1} = addlistener(labeler,...
        {'labeledpos','labeledposGT','labeledpostagGT'},... 
        'PostSet',@obj.cbkLabelUpdated);
      listeners{end+1,1} = addlistener(labeler,...
        'gtIsGTModeChanged',@obj.cbkGTIsGTModeUpdated);
      listeners{end+1,1} = addlistener(labeler,...
        'gtSuggUpdated',@obj.cbkGTSuggUpdated);
      listeners{end+1,1} = addlistener(labeler,...
        'gtSuggMFTableLbledUpdated',@obj.cbkGTSuggMFTableLbledUpdated);      
%       listeners{end+1,1} = addlistener(labeler,...
%         'labelMode','PostSet',@obj.cbkLabelMode);      
      obj.listeners = listeners;      
      obj.listenersTracker = cell(0,1);
      
      obj.tracker = [];
    
      obj.TLPROPS_TRACKER = EmptyLandmarkFeatureArray();
      obj.readTimelinePropsNew();
            
      obj.updateProps();
      obj.proptypes = InfoTimeline.TLPROPTYPES(:);

      obj.curprop = 1;
      obj.curproptype = 1;
      
      obj.jumpThreshold = nan;
      obj.jumpCondition = nan;
      
      obj.isinit = true;
      obj.hSelIm = [];
      obj.selectOn = false;
      obj.selectOnStartFrm = [];
      obj.hSegLineGT = SegmentedLine(ax,'InfoTimeline_SegLineGT');
      obj.hSegLineGTLbled = SegmentedLine(ax,'InfoTimeline_SegLineGTLbled');
      obj.isinit = false;
      
      hCMenu = uicontextmenu('parent',ax.Parent,...
        'callback',@(src,evt)obj.cbkContextMenu(src,evt),...
        'UserData',struct('bouts',nan(0,2)),...
        'Tag','InfoTimeline_ContextMenu');
      uimenu('Parent',hCMenu,'Label','Set number of frames shown',...
        'Callback',@(src,evt)obj.cbkSetNumFramesShown(src,evt),...
        'Tag','menu_InfoTimeline_SetNumFramesShown');
      obj.hCMenuClearAll = uimenu('Parent',hCMenu,...
        'Label','Clear selection (N bouts)',...
        'UserData',struct('LabelPat','Clear selection (%d bouts)'),...
        'Callback',@(src,evt)obj.selectClearSelection(),...
        'Tag','menu_InfoTimeline_selectClearSelection');
      obj.hCMenuClearBout = uimenu('Parent',hCMenu,...
        'Label','Clear bout (frame M--N)',...
        'UserData',struct('LabelPat','Clear bout (frame %d-%d)','iBout',nan),...
        'Callback',@(src,evt)obj.cbkClearBout(src,evt),...
        'Tag','menu_InfoTimeline_ClearBout');
      uimenu('Parent',hCMenu,'Label','Toggle statistic threshold visibility',...
        'Callback',@(src,evt)obj.cbkToggleThresholdViz(src,evt),...
        'Tag','menu_InfoTimeline_ToggleThresholdViz');      
      ax.UIContextMenu = hCMenu;
            
      if obj.isL,
%         hCMenuL = uicontextmenu('parent',axl.Parent);
%         uimenu('Parent',hCMenu,'Label','Set number of frames shown',...
%           'Callback',@(src,evt)obj.cbkSetNumFramesShown(src,evt));
%         obj.hCMenuClearAll(end+1) = uimenu('Parent',hCMenuL,...
%           'Label','Clear selection (N bouts)',...
%           'UserData',struct('LabelPat','Clear selection (%d bouts)'),...
%           'Callback',@(src,evt)obj.selectClearSelection());
%         obj.hCMenuClearBout(end+1) = uimenu('Parent',hCMenuL,...
%           'Label','Clear bout (frame M--N)',...
%           'UserData',struct('LabelPat','Clear bout (frame %d-%d)','iBout',nan),...
%           'Callback',@(src,evt)obj.cbkClearBout(src,evt));
%         hq = uimenu('Parent',hCMenuL,'Label','What''s this?');
%         uimenu('Parent',hq,'Label','Timeline showing which frames have been labeled');
        axl.UIContextMenu = hCMenu;
      end
      
    end
    
    function delete(obj)
      deleteValidHandles([obj.hCurrFrame,obj.hCurrFrameL,obj.hStatThresh]);
      obj.hCurrFrame = [];
      obj.hCurrFrameL = [];
      obj.hStatThresh = [];
      if ~isempty(obj.hZoom)
        delete(obj.hZoom);
      end
      if ~isempty(obj.hPan)
        delete(obj.hPan);
      end
      deleteValidHandles(obj.hPts);
      deleteValidHandles(obj.hPtStat);
      obj.hPts = [];
      obj.hPtStat = [];
      deleteValidHandles(obj.hPtsL);
      obj.hPtsL = [];
      if ~isempty(obj.listeners),
        cellfun(@delete,obj.listeners);
      end
      obj.listeners = [];
      if ~isempty(obj.listenersTracker),
        cellfun(@delete,obj.listenersTracker);
      end
      obj.listenersTracker = [];
      deleteValidHandles(obj.hSelIm);
      obj.hSelIm = [];
      deleteValidHandles(obj.hSegLineGT);
      obj.hSegLineGT = [];
      deleteValidHandles(obj.hSegLineGTLbled);
      obj.hSegLineGTLbled = [];
    end
    
  end  
  
  methods
    
    function readTimelinePropsNew(obj)

      path = fileparts(mfilename('fullpath'));
      tlpropfile = fullfile(path,obj.TLPROPFILESTR);
      assert(exist(tlpropfile,'file')>0);
      
      obj.TLPROPS = ReadLandmarkFeatureFile(tlpropfile);
      
    end
    
    function initNewProject(obj)
      obj.npts = obj.lObj.nLabelPoints;

      deleteValidHandles(obj.hPts);
      deleteValidHandles(obj.hPtStat);
      deleteValidHandles(obj.hPtsL);
      obj.hPts = gobjects(obj.npts,1);
      obj.hPtStat = gobjects(1);
      obj.hPtsL = gobjects(obj.npts,1);
      colors = obj.lObj.LabelPointColors;
      ax = obj.hAx;
      axl = obj.hAxL;
      for i=1:obj.npts
        obj.hPts(i) = plot(ax,nan,i,'.','linestyle','-','Color',colors(i,:),...
          'hittest','off','Tag',sprintf('InfoTimeline_Pt%d',i));
        if obj.isL,
          obj.hPtsL(i) = patch(axl,nan(1,5),i-1+[0,1,1,0,0],colors(i,:),'EdgeColor','none','hittest','off','Tag',sprintf('InfoTimeline_Label_%d',i));
        end
      end
      obj.hPtStat = plot(ax,nan,i,'.-','Color',obj.color,'hittest','off','LineWidth',2,'Tag','InfoTimeline_Stat');
      
      prefsTL = obj.prefs;
      ax.XColor = prefsTL.XColor;
      dy = .01;
      ax.YLim = [0-dy 1+dy];
      if obj.isL,
        axl.YLim = [0-dy obj.npts+dy];
      end
      
      set(obj.hCurrFrame,'XData',[nan nan],'ZData',[1 1]);
      set(obj.hCurrFrameL,'XData',[nan nan],'YData',[0,obj.npts],'ZData',[1 1]);
      set(obj.hStatThresh,'XData',[nan nan],'ZData',[1 1]);
      linkaxes([obj.hAx,obj.hAxL],'x');
    end
    
    function initNewMovie(obj)
%       if obj.lObj.hasMovie
%         obj.nfrm = obj.lObj.nframes;
%       else
%         obj.nfrm = 1;
%       end
      ax = obj.hAx;
      prefsTL = obj.prefs;
      ax.XTick = 0:prefsTL.dXTick:obj.nfrm;

      obj.selectInit();
      
      xlims = [1 obj.nfrm];
      SEGLINEYLOC = 1;
      sPV = struct('LineWidth',5,'Color',AxesHighlightManager.ORANGE);
      sPVLbled = struct('LineWidth',5,'Color',AxesHighlightManager.ORANGE/2);
      obj.hSegLineGT.init(xlims,SEGLINEYLOC,sPV);
      obj.hSegLineGTLbled.init(xlims,SEGLINEYLOC,sPVLbled);
      
      obj.updateProps();
      
      cbkGTSuggUpdated(obj,[],[]);
    end
    
    function updateProps(obj)
      % Set .props, .props_tracker from .TLPROPS, .TLPROPS_TRACKER
      
      % remove body features if no body tracking
      props = obj.TLPROPS;
      if ~obj.lObj.hasTrx,
        idxremove = strcmpi({props.coordsystem},'Body');
        props(idxremove) = [];
      end
      obj.props = props;      
      obj.props_tracker = cat(1,obj.props,obj.TLPROPS_TRACKER);
    end
        
    function setTracker(obj,tracker)
      
      obj.tracker = tracker;
      if ~isempty(obj.listenersTracker),
        cellfun(@delete,obj.listenersTracker);
        obj.listenersTracker = cell(0,1);
      end
      
      % Set .proptypes, .props_tracker
      if isempty(tracker),
        % AL: Probably obsolete codepath
        obj.proptypes(strcmpi(obj.proptypes,'Predictions')) = [];
        obj.props_tracker = [];
      else
        if ~ismember('Predictions',obj.proptypes),
          obj.proptypes{end+1} = 'Predictions';
        end
        obj.TLPROPS_TRACKER = tracker.propList(); %#ok<*PROPLC>
        obj.props_tracker = cat(1,obj.props,obj.TLPROPS_TRACKER);
        obj.listenersTracker{end+1,1} = addlistener(tracker,...
          'newTrackingResults',@obj.cbkLabelUpdated);
      end
      
      obj.enforcePropConsistencyWithUI(false);
      
      obj.setLabelsFull();
    end
    
    function setLabelsFull(obj)
      % Get data and set .hPts, .hMarked
      
      if isnan(obj.npts), return; end
      
      dat = obj.getDataCurrMovTgt(); % [nptsxnfrm]
      dat(isinf(dat)) = nan;
      datnonnan = dat(~isnan(dat));

      obj.tldata = dat;

      for i=1:obj.npts
        set(obj.hPts(i),'XData',nan,'YData',nan);
      end
      set(obj.hPtStat,'XData',nan,'YData',nan);
      
      if ~isempty(datnonnan)
%         set(obj.hMarked,'XData',nan,'YData',nan);
        
        y1 = min(datnonnan(:));
        y2 = max(datnonnan(:));
        if y1 == y2,
          if y1==0
            y1 = -eps;
            y2 = eps;
          else
            % y1, y2 potentially negative
            y1 = y1-abs(y1)*eps;
            y2 = y2+abs(y2)*eps;
          end
        end
        %dy = max(y2-y1,eps);
        %lposNorm = (dat-y1)/dy; % Either nan, or in [0,1]
        x = 1:size(dat,2);
        if ishandle(obj.hSelIm),
          set(obj.hSelIm,'YData',[y1,y2]);
        end
        
        set(obj.hAx,'YLim',[y1,y2]);
        set(obj.hCurrFrame,'YData',[y1,y2]);
        if size(dat,1) == obj.npts,
          for i=1:obj.npts
            set(obj.hPts(i),'XData',x,'YData',dat(i,:));
          end
        elseif size(dat,1) == 1,
          set(obj.hPtStat,'XData',x,'YData',dat(1,:));
        else
          warningNoTrace(sprintf('InfoTimeline: Number of rows in statistics was %d, expected either %d or 1',size(dat,1),obj.npts));
        end
        
        set(obj.hStatThresh,'XData',x([1 end]));
      end
      
      if obj.isL,
        islabeled = obj.getIsLabeledCurrMovTgt(); % [nptsxnfrm]
        for i = 1:obj.npts,
          if any(islabeled(i,:)),
            [t0s,t1s] = get_interval_ends(islabeled(i,:));
            nbouts = numel(t0s);
            t0s = t0s(:)'-.5; t1s = t1s(:)'-.5;
            xd = [t0s;t0s;t1s;t1s;t0s];
            yd = i-1+repmat([0;1;1;0;0],[1,nbouts]);
          else
            xd = nan;
            yd = nan;
          end
          set(obj.hPtsL(i),'XData',xd,'YData',yd);
        end
      end
      
%       markedFrms = find(any(obj.getMarkedDataCurrMovTgt(),1));
%       xxm = repmat(markedFrms,[3 1]);
%       xxm = xxm(:)+0.05; 
      % slightly off so that both current frame and labeled frame are both
      % visible.
%       yym = repmat([0 1 nan],[1 size(markedFrms,2)]);
%       set(obj.hMarked,'XData',xxm(:),'YData',yym(:));
    end
    
    function setLabelsFrame(obj,frm) %#ok<INUSD>
      % frm: [n] frame indices. Optional. If not supplied, defaults to
      % labeler.currFrame
      
      % AL20170616: Originally, timeline was not intended to listen
      % directly to Labeler.labeledpos etc; instead, notification of change
      % in labels was done by piggy-backing on Labeler.updateFrameTable*
      % (which explicitly calls this method). However, obj is now listening 
      % directly to lObj.labeledpos so this method is obsolete. Leave stub 
      % here in case need to go back to piggy-backing on
      % .updateFrameTable* eg for performance reasons.
            
%       lpos = obj.getDataCurrMovTgt();
%       for i=1:obj.npts
%         h = obj.hPts(i);
%         set(h,'XData',1:size(lpos,2),'YData',lpos(i,:));
%       end
    end
    
    function newFrame(obj,frm)
      % Respond to new .lObj.currFrame
      
      if isnan(obj.npts), return; end
            
      r = obj.prefs.FrameRadius;
      if r==0
        x0 = 1;
        x1 = obj.nfrm;
      else
        x0 = frm-r; %max(frm-r,1);
        x1 = frm+r; %min(frm+r,obj.nfrm);
      end
      obj.hAx.XLim = [x0 x1];
      set(obj.hCurrFrame,'XData',[frm frm]);
      if obj.isL,
        obj.hAxL.XLim = [x0 x1];
        set(obj.hCurrFrameL,'XData',[frm frm]);
      end
      
      if obj.selectOn
        f0 = obj.selectOnStartFrm;
        f1 = frm;
        if f1>f0
          idx = f0:f1;
        else
          idx = f1:f0;
        end
        obj.hSelIm.CData(:,idx) = 1;
      end
    end
    
    function newTarget(obj)
      obj.setLabelsFull();
    end
    
    function updateLandmarkColors(obj)
      tflbl = obj.getCurPropTypeIsLabel();
      lblcolors = obj.lObj.LabelPointColors();
      if tflbl
        ptclrs = lblcolors;
      else
        ptclrs = obj.lObj.PredictPointColors();
      end
      for i=1:obj.npts
        set(obj.hPts(i),'Color',ptclrs(i,:));
      end
      if obj.isL,
        for i=1:obj.npts
          set(obj.hPtsL(i),'FaceColor',lblcolors(i,:));
        end
      end
    end
    
    function selectInit(obj)
      if obj.lObj.isinit || isnan(obj.nfrm), return; end

      deleteValidHandles(obj.hSelIm);
      obj.hSelIm = image(1:obj.nfrm,0.5,uint8(zeros(1,obj.nfrm)),...
        'parent',obj.hAx,'HitTest','off',...
        'CDataMapping','direct');

      obj.selectOn = false;
      obj.selectOnStartFrm = [];
      colorTBSelect = obj.lObj.gdata.tbTLSelectMode.BackgroundColor;
      colormap(obj.hAx,[0 0 0;colorTBSelect]);
      
      obj.setLabelerSelectedFrames();
    end

    function bouts = selectGetSelection(obj)
      % Get currently selected bouts (can be noncontiguous)
      %
      % bouts: [nBout x 2]. col1 is startframe, col2 is one-past-endframe

      cdata = obj.hSelIm.CData;
      [sp,ep] = get_interval_ends(cdata);
      bouts = [sp(:) ep(:)];
    end
    
    function selectClearSelection(obj)
      obj.selectInit();
    end
    
    function setStatThresh(obj,th)
      obj.hStatThresh.YData = [th th];
    end
    
    function setStatThreshViz(obj,tfshow)
      % show stat threshold and y-axis labels/ticks
      onoff = onIff(tfshow);
      obj.hStatThresh.Visible = onoff;
      if tfshow
        obj.hAx.YColor = obj.hAx.XColor;
      else
        obj.hAx.YColor = [0.15 0.15 0.15];
      end
    end
        
%     function setJumpParams(obj)
%       % GUI to get jump parameters,
%       f = figure('Visible','on','Position',[360,500,200,90],...
%         'MenuBar','None','ToolBar','None');
%       tbottom = 70;
%       uicontrol('Style','text',...
%                    'String','Jump To:','Value',1,'Position',[10,tbottom,190,20]);
%       
%       ibottom = 50;           
%       hprop = uicontrol('Style','Text',...
%                    'String','drasdgx','Value',1,'Position',[10,ibottom-2,90,20],...
%                    'HorizontalAlignment','left');
%       hprope = get(hprop,'Extent');
%       st = hprope(3) + 15;
%       hCondition = uicontrol('Style','popupmenu',...
%                    'String',{'>','<='},'Value',1,'Position',[st,ibottom,40,20]);
%       hval = uicontrol('Style','edit',...
%                    'String','0','Position',[st+55,ibottom-2,30,20]);           
%       bbottom = 10;
% 
% 
%       uicontrol('Style','pushbutton',...
%                    'String','Cancel','Position',[30,bbottom,60,30],'Callback',{fcancel,f});
%       uicontrol('Style','pushbutton',...
%                    'String','Done','Position',[110,bbottom,60,30],...
%                    'Callback',{fapply,f,hCondition,hval,obj});
%                  
%       function fcancel(~,~,f)
%         delete(f);
%       end
%       
%       function fapply(~,~,f,hCondition,hval,obj) 
%         tr = str2double(get(hval,'String'));
%         if isnan(tr)
%           warndlg('Enter valid numerical value');
%           return;
%         end
%         obj.jumpThreshold = tr;
%         obj.jumpCondition = 2*get(hCondition,'Value')-3;
%         delete(f);
%       end
%     end
    
    function v = isL(obj)
      v = ~isempty(obj.hAxL) && ishandle(obj.hAxL);
    end
    
  end
  
  methods %getters setters
    function enforcePropConsistencyWithUI(obj,tfSetLabelsFull)
      % Checks that .curprop is in range for current .props,
      % .props_tracker, .curproptype. 
      %
      % Theoretically this check is necessary whenever .curprop, .props,
      % .props_tracker, .curproptype change.
      %
      % If it is not, it resets .curprop, resets lObj.gdata.pumInfo.Value,
      % and optionally calls setLabelsFull (only optional to avoid
      % redundant/dup calls near callsite).

      ptype = obj.proptypes{obj.curproptype};
      switch ptype
        case 'Predictions'
          tfOOB = obj.curprop > numel(obj.props_tracker);
        otherwise
          tfOOB = obj.curprop > numel(obj.props);
      end
      
      if tfOOB
        NEWPROP = 1;
        obj.curprop = NEWPROP;
        obj.lObj.gdata.pumInfo.Value = NEWPROP;
      end
      
      if tfSetLabelsFull
        obj.setLabelsFull();
      end
    end
    function props = getPropsDisp(obj,ipropType)
      % Get available properties for given propType (idx)
      if nargin < 2,
        ipropType = obj.curproptype;
      end
      if strcmpi(obj.proptypes{ipropType},'Predictions'),
        props = {obj.props_tracker.name};
      else
        props = {obj.props.name};
      end
    end
    function proptypes = getPropTypesDisp(obj)
      proptypes = obj.proptypes;
    end
    function setCurProp(obj,iprop)
      % setLabelsFull will essentially assert that iprop is in range for
      % current proptype.
      %
      % Does not update UI
      obj.curprop = iprop;
      obj.setLabelsFull();
    end
    function setCurPropType(obj,iproptype,iprop)
      % iproptype, iprop assumed to be consistent already.
      obj.curproptype = iproptype;
      if nargin >= 3 && iprop ~= obj.curprop,
        obj.curprop = iprop;
      end
      obj.setLabelsFull();
      obj.updateLandmarkColors();
    end
    function [ptype,prop] = getCurPropSmart(obj)
      % Get current proptype, and prop-specification-struct
      
      ptype = obj.proptypes{obj.curproptype};
      switch ptype
        case 'Predictions'
          prop = obj.props_tracker(obj.curprop);
        otherwise
          prop = obj.props(obj.curprop);
      end
    end
    function tf = getCurPropTypeIsLabel(obj)
      v = obj.curproptype;
      tf = strcmp(obj.proptypes{v},'Labels');
    end
  end
    
  %% Private methods
  methods (Access=private) % callbacks
    function cbkBDF(obj,src,evt) 
      if ~obj.lObj.isReady,
        return;
      end
      
      if ~(obj.lObj.hasProject && obj.lObj.hasMovie)
        return;
      end

      if evt.Button==1
        % Navigate to clicked frame
        
        pos = get(src,'CurrentPoint');
        frm = round(pos(1,1));
        frm = min(max(frm,1),obj.nfrm);
        obj.lObj.setFrame(frm);
      end
    end
%     function cbkLabelMode(obj,src,evt) %#ok<INUSD>
% %       onoff = onIff(obj.lObj.labelMode==LabelMode.ERRORCORRECT);
%       onoff = 'off';
%       set(obj.hMarked,'Visible',onoff);
%     end
    function cbkLabelUpdated(obj,src,~) %#ok<INUSD>
      if ~obj.lObj.isinit
        obj.setLabelsFull;
      end
    end
    function cbkSetNumFramesShown(obj,src,evt) %#ok<INUSD>
      frmRad = obj.prefs.FrameRadius;
      aswr = inputdlg('Number of frames (0 to show full movie)',...
        'Timeline',1,{num2str(2*frmRad)});
      if ~isempty(aswr)
        nframes = str2double(aswr{1});
        validateattributes(nframes,{'numeric'},{'nonnegative' 'integer'});
        obj.lObj.projPrefs.InfoTimelines.FrameRadius = round(nframes/2);
        obj.newFrame(obj.lObj.currFrame);
      end
    end
    function cbkToggleThresholdViz(obj,src,evt)
      tfviz = strcmp(obj.hStatThresh.Visible,'on');
      obj.setStatThreshViz(~tfviz);
    end
    function cbkContextMenu(obj,src,evt)  %#ok<INUSD>
      bouts = obj.selectGetSelection;
      nBouts = size(bouts,1);
      src.UserData.bouts = bouts;

      % Fill in bout number in "clear all" menu item
      hMnuClearAll = obj.hCMenuClearAll;
      set(hMnuClearAll,'Label',sprintf(hMnuClearAll.UserData.LabelPat,nBouts));
      
      % figure out if user clicked within a bout
      pos = get(obj.hAx,'CurrentPoint');
      frmClick = pos(1);
      tf = bouts(:,1)<=frmClick & frmClick<=bouts(:,2);
      iBout = find(tf);
      tfClickedInBout = ~isempty(iBout);
      hMnuClearBout = obj.hCMenuClearBout;
      set(hMnuClearBout,'Visible',onIff(tfClickedInBout));
      if tfClickedInBout
        assert(isscalar(iBout));
        set(hMnuClearBout,'Label',sprintf(hMnuClearBout.UserData.LabelPat,...
          bouts(iBout,1),bouts(iBout,2)-1));
        for i = 1:numel(hMnuClearBout),
          hMnuClearBout(i).UserData.iBout = iBout;  % store bout that user clicked in
        end
      end
    end
    function cbkClearBout(obj,src,evt) %#ok<INUSD>
      % Prob should have a select* method, for now just do everything here
      iBout = src.UserData.iBout;
      boutsAll = src.Parent.UserData.bouts;
      bout = boutsAll(iBout,:);
      obj.hSelIm.CData(:,bout(1):bout(2)-1) = 0;
      obj.setLabelerSelectedFrames();
    end    
    function cbkGTIsGTModeUpdated(obj,src,evt) %#ok<INUSD>
      lblObj = obj.lObj;
      gt = lblObj.gtIsGTMode;
      if gt
        obj.cbkGTSuggUpdated([],[]);
      end
      onOff = onIff(gt);
      obj.hSegLineGT.setVisible(onOff);
      obj.hSegLineGTLbled.setVisible(onOff);
    end
    function cbkGTSuggUpdated(obj,src,evt) %#ok<INUSD>
      % full update to any change to labeler.gtSuggMFTable*
      
      lblObj = obj.lObj;
      if lblObj.isinit || ~lblObj.hasMovie || ~lblObj.gtIsGTMode
        % segLines are not visible; more importantly, cannot set segLine
        % highlighting based on suggestions in current movie
        return;
      end
      
      % find rows for current movie
      tblLbled = table(lblObj.gtSuggMFTableLbled,'variableNames',{'hasLbl'});
      tbl = [lblObj.gtSuggMFTable tblLbled];
      mIdx = lblObj.currMovIdx;
      tf = mIdx==tbl.mov;
      tblCurrMov = tbl(tf,:); % current mov, various frm/tgts
      
      % for hSegLineGT, we highlight any/all frames (regardless of, or across all, targets)
      frmsOn = tblCurrMov.frm; % could contain repeat frames (across diff targets)
      obj.hSegLineGT.setOnAtOnly(frmsOn);
      
      % For hSegLineGTLbled, we turn on a given frame only if all
      % targets/rows for that frame are labeled.
      tblRes = rowfun(@(zzHasLbl)all(zzHasLbl),tblCurrMov,...
        'groupingVariables',{'frm'},'inputVariables','hasLbl',...
        'outputVariableNames',{'allTgtsLbled'});
      frmsAllTgtsLbled = tblRes.frm(tblRes.allTgtsLbled);
      obj.hSegLineGTLbled.setOnAtOnly(frmsAllTgtsLbled);
    end
    function cbkGTSuggMFTableLbledUpdated(obj,src,evt) %#ok<INUSD>
      % React to incremental update to labeler.gtSuggMFTableLbled
      
      lblObj = obj.lObj;
      if ~lblObj.gtIsGTMode
        % segLines are not visible,; more importantly, cannot set segLine
        % highlighting based on suggestions in current movie
        return;
      end
      
      % find rows for current movie/frm
      tbl = lblObj.gtSuggMFTable;
      currFrm = lblObj.currFrame;
      tfCurrMovFrm = tbl.mov==lblObj.currMovIdx & tbl.frm==currFrm;
      tfLbled = lblObj.gtSuggMFTableLbled;
      tfLbledCurrMovFrm = tfLbled(tfCurrMovFrm,:);
      tfHiliteOn = numel(tfLbledCurrMovFrm)>0 && all(tfLbledCurrMovFrm);
      obj.hSegLineGTLbled.setOnOffAt(currFrm,tfHiliteOn);
    end
    
    function cbkPostZoom(obj,src,evt) %#ok<INUSD>
      if ishandle(obj.hSelIm),
        obj.hSelIm.YData = obj.hAx.YLim;
      end
    end
    
  end

  methods (Access=private)
    function setLabelerSelectedFrames(obj)
      % For the moment Labeler owns the property-of-record on what frames
      % are set
      selFrames = bouts2frames(obj.selectGetSelection);
      obj.lObj.setSelectedFrames(selFrames);
    end

    function data = getDataCurrMovTgt(obj)
      % lpos: [nptsxnfrm]
      
      [ptype,pcode] = obj.getCurPropSmart();
      labeler = obj.lObj;
      iMov = labeler.currMovie;
      iTgt = labeler.currTarget;
      
      if isempty(iMov) || iMov==0 
        data = nan(obj.npts,1);
      else
        switch ptype
          case {'Labels','Imported'}
            needtrx = obj.lObj.hasTrx && strcmpi(pcode.coordsystem,'Body');
            if needtrx,
              trxFile = obj.lObj.trxFilesAllFullGTaware{iMov,1};
              bodytrx = obj.lObj.getTrx(trxFile,obj.lObj.movieInfoAllGTaware{iMov,1}.nframes);
              bodytrx = bodytrx(iTgt);
            else
              bodytrx = [];
            end
            if strcmp(ptype,'Labels'),
            lpos = labeler.labeledposGTaware{iMov};
              lpostag = labeler.labeledpostagGTaware{iMov};
            else
              lpos = labeler.labeledpos2GTaware{iMov};
              lpostag = false(obj.npts,labeler.nframes,labeler.nTargets);
            end
            data = ComputeLandmarkFeatureFromPos(lpos(:,:,:,iTgt),...
              lpostag(:,:,iTgt),bodytrx,pcode);
          case 'Predictions'
            data = obj.tracker.getPropValues(pcode);
          otherwise
            error('Unknown data type %s',ptype);
        end
        %szassert(data,[obj.npts obj.nfrm]);
      end
    end
    
    function data = getIsLabeledCurrMovTgt(obj)
      % lpos: [nptsxnfrm]
      
      labeler = obj.lObj;
      iMov = labeler.currMovie;
      iTgt = labeler.currTarget;
      
      if isempty(iMov) || iMov==0 || ~labeler.hasMovie
        data = nan(obj.npts,1);
      else
        data = reshape(all(~isnan(labeler.labeledposGTaware{iMov}(:,:,:,iTgt)),2),[obj.npts,obj.nfrm]);
        szassert(data,[obj.npts obj.nfrm]);
      end
    end
    
%     function lpos = getMarkedDataCurrMovTgt(obj)
%       % lpos: [nptsxnfrm]
%       
%       labeler = obj.lObj;
%       iMov = labeler.currMovie;
%       if iMov>0
%         if ~labeler.gtIsGTMode
%           iTgt = labeler.currTarget;
%           lpos = squeeze(labeler.labeledposMarked{iMov}(:,:,iTgt)); % AL: squeeze seems unnec
%         else
%           lpos = false(labeler.nLabelPoints,labeler.nframes);
%         end
%       else
%         lpos = false(labeler.nLabelPoints,1);
%       end
%     end
    
%     function nxtFrm = findFrame(obj,dr,curFr)
%       % Finds the next or previous frame which satisfy conditions.
%       % dr = 0 is back, 1 is forward
%       nxtFrm = nan;
%       if isnan(obj.jumpThreshold)
%         warndlg('Threhold value is not for navigation');
%         obj.thresholdGUI();
%         if isnan(obj.jumpThreshold)
%           return;
%         end
%       end
%       
%       data = obj.getDataCurrMovTgt();
%       if obj.jumpCondition > 0
%         locs = any(data>obj.jumpThreshold,1);
%       else
%         locs = any(data<=obj.jumpThreshold,1);
%       end
%       
%       if dr > 0.5
%         locs = locs(curFr:end);
%         nxtlocs = find( (~locs(1:end-1))&(locs(2:end)),1);
%         if isempty(nxtlocs)
%           return;
%         end
%         nxtFrm = curFr + nxtlocs - 1;
%       else
%         locs = locs(1:curFr);
%         nxtlocs = find( (locs(1:end-1))&(~locs(2:end)),1,'last');
%         if isempty(nxtlocs)
%           return;
%         end
%         nxtFrm = nxtlocs;
%       end
%     end
  end
  
end

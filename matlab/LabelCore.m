classdef LabelCore < handle
% Labeling base class 
%
% Handles the details of labeling: the labeling state machine, managing 
% in-progress labels, etc.
%
% LabelCore intercepts all axes_curr (and children) BDFs, figure
% Window*Fcns, figure keypresses, and tbAccept/pbClear signals to
% implement the labeling state machine; ie labelng is enabled by ptsBDF,
% figWBMF, figWBUF acting in concert. When labels are accepted, they are
% written back to the Labeler.
%
% Labeler provides LabelCore with target/frame transitions, trx info,
% accepted labels info. LabelCore read/writes labeledpos through
% Labeler's API, and for convenience directly manages limited uicontrols
% on LabelerGUI (pbClear, tbAccept).
  
  properties (Constant,Hidden)
    DT2P = 5;
    DXFAC = 500;
    DXFACBIG = 50;
  end
  
  properties (Abstract)
    supportsSingleView % scalar logical
    supportsMultiView % scalar logical
    supportsCalibration % scalar logical
  end
  
  properties (SetObservable)
    hideLabels; % scalar logical
  end
        
  properties % handles
    labeler;              % scalar Labeler obj
    hFig;                 % [nview] figure handles (first is main fig)
    hAx;                  % [nview] axis handles (first is main axis)
    hIms;                 % [nview] image handles
    hAxOcc;               % [nview] scalar handle, occluded-axis
    tbAccept;             % scalar handle, togglebutton
    pbClear;              % scalar handle, clearbutton
    txLblCoreAux;         % scalar handle, auxiliary text (currently primary axis only)

    hPts;                 % nPts x 1 handle vec, handle to points
    hPtsTxt;              % nPts x 1 handle vec, handle to text
    hPtsOcc;              % nPts x 1 handle vec, handle to occ points
    hPtsTxtOcc;           % nPts x 1 handle vec, handle to occ text
    hSkel;                % nEdges x 1 handle vec, handle to skeleton edges
    ptsPlotInfo;          % struct, points plotting cosmetic info    
  end

  properties
    nPts;                 % scalar integer 
    state;                % scalar LabelState

    % Optional logical "decorator" flags 
    % 
    % These flags provide additional metadata/state for labeled landmarks.
    % 
    % Use of these flags is not mandatory in subclasses, but it occurs 
    % frequently. For convenience/code-sharing purposes the state lives
    % here. LabelCore utilities can aid in the maintenance of this state;
    % and if this state is properly maintained, LabelCore utilities can be
    % utilized to write to Labeler as appropriate.
    
    tfOcc;                % [nPts x 1] logical. Fully occluded.
    tfEstOcc;             % [nPts x 1] logical. Estimated-occluded.
                          %   (HT mode does not use .tfEstOcc, relies on
                          %   markers.)
    tfSel;                % [nPts x 1] logical. If true, pt is currently selected.
  end
  
  methods (Static)
    
    function obj = createSafe(labelerObj,labelMode)
      if labelerObj.isMultiView && labelMode~=LabelMode.MULTIVIEWCALIBRATED2
        labelModeOldStr = labelMode.prettyString;
        labelMode = LabelMode.MULTIVIEWCALIBRATED2;
        warningNoTrace('LabelCore:mv',...
          'Labeling mode ''%s'' does not support multiview projects. Using mode ''%s''.',...
        labelModeOldStr,labelMode.prettyString);
      elseif ~labelerObj.isMultiView && labelMode==LabelMode.MULTIVIEWCALIBRATED2
        labelModeOldStr = labelMode.prettyString;
        labelMode = LabelMode.TEMPLATE;
        warningNoTrace('LabelCore:mv',...
          'Labeling mode ''%s'' cannot be used for single-view projects. Using mode ''%s''.',...
          labelModeOldStr,labelMode.prettyString);
      end
      obj = LabelCore.create(labelerObj,labelMode);
    end
    function obj = create(labelerObj,labelMode)
      switch labelMode
        case LabelMode.SEQUENTIAL
          obj = LabelCoreSeq(labelerObj);
        case LabelMode.TEMPLATE
          obj = LabelCoreTemplate(labelerObj);
        case LabelMode.HIGHTHROUGHPUT
          obj = LabelCoreHT(labelerObj);
%         case LabelMode.ERRORCORRECT
%           obj = LabelCoreErrorCorrect(labelerObj);
%         case LabelMode.MULTIVIEWCALIBRATED
%           obj = LabelCoreMultiViewCalibrated(labelerObj);
        case LabelMode.MULTIVIEWCALIBRATED2
          obj = LabelCoreMultiViewCalibrated2(labelerObj);
      end
      
    end
    
  end
  
  methods (Sealed=true)
    
    function obj = LabelCore(labelerObj)
      if labelerObj.isMultiView && ~obj.supportsMultiView
        error('LabelCore:MV','Multiview labeling not supported by %s.',...
          class(obj));
      end

      obj.labeler = labelerObj;
      gd = labelerObj.gdata;
      obj.hFig = gd.figs_all;
      obj.hAx = gd.axes_all;
      obj.hIms = gd.images_all;
      obj.hAxOcc = gd.axes_occ;
      obj.tbAccept = gd.tbAccept;
      obj.pbClear = gd.pbClear;
      obj.txLblCoreAux = gd.txLblCoreAux;
    end
    
    function init(obj,nPts,ptsPlotInfo)
      obj.nPts = nPts;
      obj.ptsPlotInfo = ptsPlotInfo;
      
      deleteValidHandles(obj.hPts);
      deleteValidHandles(obj.hPtsOcc);
      deleteValidHandles(obj.hPtsTxt);
      deleteValidHandles(obj.hPtsTxtOcc);
      deleteValidHandles(obj.hSkel);
      obj.hPts = gobjects(obj.nPts,1);
      obj.hPtsOcc = [];
      obj.hPtsTxt = gobjects(obj.nPts,1);
      obj.hPtsTxtOcc = [];      
      
      ax = obj.hAx;
      obj.updateSkeletonEdges(ax,ptsPlotInfo);
      
      pvMarker = struct2paramscell(ptsPlotInfo.MarkerProps);
      pvText = struct2paramscell(ptsPlotInfo.TextProps);
      
      for i = 1:obj.nPts
        ptsArgs = {nan,nan,pvMarker{:},'Color',ptsPlotInfo.Colors(i,:),...
          'UserData',i}; %#ok<CCAT>
        obj.hPts(i) = plot(ax(1),ptsArgs{:},'Tag',sprintf('LabelCore_Pts_%d',i));
        obj.hPtsTxt(i) = text(nan,nan,num2str(i),'Parent',ax(1),...
          pvText{:},...
          'Color',ptsPlotInfo.Colors(i,:),...
          'PickableParts','none',...
          'Tag',sprintf('LabelCore_Pts_%d',i));
      end
      obj.hideLabels = false;
      obj.updateShowSkeleton();
            
      set(obj.hAx,'ButtonDownFcn',@(s,e)obj.axBDF(s,e));      
      arrayfun(@(x)set(x,'HitTest','on','ButtonDownFcn',@(s,e)obj.ptBDF(s,e)),obj.hPts);
      gdata = obj.labeler.gdata;
      set(gdata.uipanel_curr,'ButtonDownFcn',@(s,e)obj.pnlBDF(s,e));
      
      set(gdata.tbAccept,'Enable','on');
      set(gdata.pbClear,'Enable','on');
      obj.labeler.currImHud.updateReadoutFields('hasLblPt',false);
      
      obj.tfOcc = false(obj.nPts,1);
      obj.tfEstOcc = false(obj.nPts,1);
      obj.tfSel = false(obj.nPts,1);
      
      if obj.labeler.showOccludedBox
        obj.showOcc();
      end
      
      obj.txLblCoreAux.Visible = 'off';
      units0 = obj.txLblCoreAux.FontUnits;
      obj.txLblCoreAux.FontUnits = 'pixels';
      obj.txLblCoreAux.FontSize = 12;
      obj.txLblCoreAux.FontUnits = units0;
      
      obj.initHook();
    end
    
    function showOcc(obj)
            
      deleteValidHandles(obj.hPtsOcc);
      deleteValidHandles(obj.hPtsTxtOcc);
      obj.hPtsOcc = gobjects(obj.nPts,1);
      obj.hPtsTxtOcc = gobjects(obj.nPts,1);
      
      axOcc = obj.hAxOcc;
      
      pvMarker = struct2paramscell(obj.ptsPlotInfo.MarkerProps);
      pvText = struct2paramscell(obj.ptsPlotInfo.TextProps);
      
      for i = 1:obj.nPts
        ptsArgs = {nan,nan,pvMarker{:},...
          'Color',obj.ptsPlotInfo.Colors(i,:),...
          'UserData',i}; %#ok<CCAT>
        obj.hPtsOcc(i) = plot(axOcc(1),ptsArgs{:},'Tag',sprintf('LabelCore_PtsOcc_%d',i));
        obj.hPtsTxtOcc(i) = text(nan,nan,num2str(i),'Parent',axOcc(1),...
          pvText{:},...
          'Color',obj.ptsPlotInfo.Colors(i,:),...
          'PickableParts','none',...
          'Tag',sprintf('LabelCore_Pts_%d',i));
      end
            
      set(obj.hAxOcc,'ButtonDownFcn',@(s,e)obj.axOccBDF(s,e));
      
      obj.showOccHook();
      
      obj.refreshOccludedPts();
    end
    
    function hideOcc(obj)
      deleteValidHandles(obj.hPtsOcc);
      deleteValidHandles(obj.hPtsTxtOcc);
      obj.hPtsOcc = [];
      obj.hPtsTxtOcc = [];
      set(obj.hAxOcc,'ButtonDownFcn','');
    end
           
  end
  
  methods
    function delete(obj)
      deleteValidHandles(obj.hPts);
      deleteValidHandles(obj.hPtsTxt);
      deleteValidHandles(obj.hPtsOcc);
      deleteValidHandles(obj.hPtsTxtOcc);
      deleteValidHandles(obj.hSkel);
    end
  end
  
  methods % public API
    
    function initHook(obj) %#ok<MANU>
      % Called from Labeler.labelingInit->LabelCore.init
    end
    
    function showOccHook(obj) %#ok<MANU>
      
    end

    function newFrame(obj,iFrm0,iFrm1,iTgt) %#ok<INUSD>
      % Frame has changed, Target is the same
      %
      % Called from Labeler.setFrame->Labeler.labelsUpdateNewFrame      
    end
    
    function newTarget(obj,iTgt0,iTgt1,iFrm) %#ok<INUSD>
      % Target has changed, Frame is the same
      %
      % Called from Labeler.labelsUpdateNewTarget
    end
    
    function newFrameAndTarget(obj,iFrm0,iFrm1,iTgt0,iTgt1) %#ok<INUSD>
      % Frame and Target have both changed
      %
    end
    
    function clearLabels(obj) %#ok<MANU>
      % Clear current labels and enter initial labeling state
      %
      % Called from pbClear and Labeler.labelingInit
    end
    
    function acceptLabels(obj) %#ok<MANU>
      % Called from tbAccept/Unaccept
    end    
    
    function unAcceptLabels(obj) %#ok<MANU>
      % Called from tbAccept/Unaccept
    end    
    
    function axBDF(obj,src,evt) %#ok<INUSD>
    end
    
    function ptBDF(obj,src,evt) %#ok<INUSD>
    end
    
    function wbmf(obj,src,evt) %#ok<INUSD>
    end
    
    function wbuf(obj,src,evt) %#ok<INUSD>
    end
    
    function pnlBDF(obj,src,evt) 
      
      if ~obj.labeler.isReady,
        return;
      end
      
      % This is called when uipanel_curr is clicked outside the axis, or
      % when points with HitTest off plotted in overlaid axes are clicked.
      pos = get(obj.hAx(1),'CurrentPoint');
      pos = pos(1,1:2);
      xlim = get(obj.hAx(1),'XLim');
      ylim = get(obj.hAx(1),'YLim');
      if pos(1)>=xlim(1) && pos(1)<=xlim(2) && pos(2)>=ylim(1) && pos(2)<=ylim(2)
        obj.axBDF(src,evt);
      end
    end
    
    function axOccBDF(obj,src,evt) %#ok<INUSD>
    end
    
    function tfKPused = kpf(obj,src,evt) %#ok<INUSD>
      % KeyPressFcn
      % 
      % tfKPused: if true, keypress has been consumed by LabelCore. 
      % LabelCore has first dibs on keypresses. Unconsumed keypresses may 
      % be passed onto other clients (eg Timeline)

      % Default implementation does nothing and never consumes
      tfKPused = false;
    end
    
    function getLabelingHelp(obj) %#ok<MANU>
    end
    
    % Cosmetics: see "Cosmetics notes" in Labeler.m

    function updateColors(obj,colors)
      % Colors apply to both markers and textlbls
      
      obj.ptsPlotInfo.Colors = colors;
      
      for i = 1:obj.nPts
        if numel(obj.hPts) >= i && ishandle(obj.hPts(i)),
          set(obj.hPts(i),'Color',obj.ptsPlotInfo.Colors(i,:));
        end
        if numel(obj.hPtsOcc) >= i && ishandle(obj.hPtsOcc(i)),
          set(obj.hPtsOcc(i),'Color',obj.ptsPlotInfo.Colors(i,:));
        end
        if numel(obj.hPtsTxt) >= i && ishandle(obj.hPtsTxt(i)),
          set(obj.hPtsTxt(i),'Color',obj.ptsPlotInfo.Colors(i,:));
        end
        if numel(obj.hPtsTxtOcc) >= i && ishandle(obj.hPtsTxtOcc(i)),
          set(obj.hPtsTxtOcc(i),'Color',obj.ptsPlotInfo.Colors(i,:));
        end
      end
      % TO DO uncomment
%       for i = 1:numel(obj.hSkel),
%         color = obj.ptsPlotInfo.Colors(obj.labeler.skeletonEdgeColor(i),:);
%         set(obj.hSkel(i),'Color',color);
%       end
    end
    
    function updateMarkerCosmetics(obj,pvMarker)
      flds = fieldnames(pvMarker);
      for f=flds(:)',f=f{1}; %#ok<FXSET>
        obj.ptsPlotInfo.MarkerProps.(f) = pvMarker.(f);
      end
      set(obj.hPts,pvMarker);
    end
    
    function updateTextLabelCosmetics(obj,pvText,txtoffset)
      flds = fieldnames(pvText);
      for f=flds(:)',f=f{1}; %#ok<FXSET>
        obj.ptsPlotInfo.TextProps.(f) = pvText.(f);
      end
      set(obj.hPtsTxt,pvText);
      
      obj.ptsPlotInfo.TextOffset = txtoffset;      
      obj.redrawTextLabels(); % to utilize txtoffset
    end
    
    function edges = skeletonEdges(obj)
      
      edges = obj.labeler.skeletonEdges;
      
    end
    
    function updateSkeletonEdges(obj,ax,ptsPlotInfo)
      
      if nargin < 2 || isempty(ax),
        ax = obj.hAx;
      end
      if nargin < 3 || isempty(ptsPlotInfo),
        ptsPlotInfo = obj.ptsPlotInfo;
      end
      
      deleteValidHandles(obj.hSkel);
      obj.hSkel = gobjects(size(obj.skeletonEdges,1),1);
      for i = 1:size(obj.skeletonEdges,1),
        %color = ptsPlotInfo.Colors(obj.labeler.skeletonEdgeColor(i),:);
        color = [.7,.7,.7];
        obj.hSkel(i) = LabelCore.initSkeletonEdge(ax,i,ptsPlotInfo,color);
      end
      xy = obj.getLabelCoords();
      tfOccld = any(isinf(xy),2);
      LabelCore.setSkelCoords(xy,tfOccld,obj.hSkel,obj.skeletonEdges);
      
    end
    
    
  end
  
  %% 
  methods % show/hide viz
    
    function labelsHide(obj)
      [obj.hPts.Visible] = deal('off');
      [obj.hPtsTxt.Visible] = deal('off'); 
      obj.hideLabels = true;
      obj.updateShowSkeleton();
    end
    
    function labelsShow(obj)
      [obj.hPts.Visible] = deal('on');
      [obj.hPtsTxt.Visible] = deal('on');
      obj.hideLabels = false;
      obj.updateShowSkeleton();
    end
    
    function labelsHideToggle(obj)
      if obj.hideLabels
        obj.labelsShow();
      else
        obj.labelsHide();
      end
    end    
    
    function updateShowSkeleton(obj)
      if isempty(obj.hSkel),
        return;
      end
      if obj.labeler.showSkeleton && ~obj.hideLabels,
        [obj.hSkel.Visible] = deal('on');
      else
        [obj.hSkel.Visible] = deal('off');
      end
    end
        
  end
  
  %% 
  
  methods (Hidden) % Utilities
    
    % AL20170623 This meth is confused.
    function assignLabelCoords(obj,xy,varargin)
      % Assign specified label points xy to .hPts, .hPtsTxt; set .tfOcc
      % based on xy (in case of tfMainAxis)
      % 
      % xy: .nPts x 2 coordinate array in Labeler format. NaNs=missing,
      % inf=occluded. NaN points get set to NaN (so will not be visible);
      % Inf points get positioned in the occluded box.
      % 
      % Optional PVs:
      % - tfClip: Default false. If true, clip xy to movie size as necessary
      % - hPts: vector of handles to assign to. Must have .nPts elements. 
      %   Defaults to obj.hPts.
      % - hPtsTxt: vector of handles for text labels, etc. Defaults to
      % obj.hPtsTxt.
      % - lblTags: [nptsx1] logical array. If supplied, obj.tfEstOcc and 
      % obj.hPts.Marker are updated.

      %ticinfo = tic;
      [tfClip,hPoints,hPointsTxt,hSkel,lblTags] = myparse(varargin,...
        'tfClip',false,...
        'hPts',obj.hPts,...
        'hPtsTxt',obj.hPtsTxt,...
        'hSkel',obj.hSkel,...
        'lblTags',[]); %#ok<PROPLC>
      
      assert(isequal(obj.nPts,numel(hPoints),numel(hPointsTxt),size(xy,1)));
      tfLblTags = ~isempty(lblTags);
      if tfLblTags
        validateattributes(lblTags,{'logical'},{'vector' 'numel' obj.nPts});
      end        
      %fprintf('LabelCore.assignLabelCoords 1: %f\n',toc(ticinfo));ticinfo = tic;
      if tfClip        
        lbler = obj.labeler;
        
        assert(~lbler.isMultiView,'Multi-view labeling unsupported.');
        
        roi = lbler.movieroi;
        xyOrig = xy;        
        tfRealCoord = ~isnan(xy) & ~isinf(xy);
        xy(tfRealCoord(:,1),1) = max(xy(tfRealCoord(:,1),1),roi(1));
        xy(tfRealCoord(:,1),1) = min(xy(tfRealCoord(:,1),1),roi(2)); 
        xy(tfRealCoord(:,2),2) = max(xy(tfRealCoord(:,2),2),roi(3));
        xy(tfRealCoord(:,2),2) = min(xy(tfRealCoord(:,2),2),roi(4));
        if ~isequaln(xy,xyOrig)
          warningNoTrace('LabelCore:clipping',...
            'Clipping points that extend beyond movie size.');
        end
      end
      %fprintf('LabelCore.assignLabelCoords 2: %f\n',toc(ticinfo));ticinfo = tic;
            
      % FullyOccluded
      tfOccld = any(isinf(xy),2);
      obj.setPtsCoords(xy(~tfOccld,:),hPoints(~tfOccld),hPointsTxt(~tfOccld));
      
      % set skeleton coords
      LabelCore.setSkelCoords(xy,tfOccld,hSkel,obj.skeletonEdges); %#ok<PROPLC>
      
      %fprintf('LabelCore.assignLabelCoords 3: %f\n',toc(ticinfo));ticinfo = tic;
      
      tfMainAxis = isequal(hPoints,obj.hPts) && isequal(hPointsTxt,obj.hPtsTxt);
      if tfMainAxis
        obj.tfOcc = tfOccld;
        obj.refreshOccludedPts();
      else
        obj.setPtsCoords(nan(nnz(tfOccld),2),hPoints(tfOccld),hPointsTxt(tfOccld));
      end
      %fprintf('LabelCore.assignLabelCoords 4: %f\n',toc(ticinfo));ticinfo = tic;
      
      % Tags
      if tfLblTags
        tfEO = lblTags;
        if any(tfOccld & tfEO)
          warning('LabelCore:occ',...
            'Points labeled as both fully and estimated-occluded.');
          
        end
        obj.tfEstOcc = tfEO;
        obj.refreshPtMarkers();
      else
        % none; tfEstOcc, hPts markers unchanged
      end
      %fprintf('LabelCore.assignLabelCoords 5: %f\n',toc(ticinfo));ticinfo = tic;

    end
    
    function assignLabelCoordsIRaw(obj,xy,iPt)
      % Set coords for hPts(iPt), hPtsTxt(iPt)
      %
      % Unlike assignLabelCoords, no clipping or occluded-handling
      hPoint = obj.hPts(iPt);
      hTxt = obj.hPtsTxt(iPt);
      obj.setPtsCoords(xy,hPoint,hTxt);
      
      % update edges connected
      for i = 1:numel(iPt),
        [js,ks] = find(obj.skeletonEdges==iPt(i));
        for jj = 1:numel(js),
          j = js(jj);
          k = ks(jj);
          xdata = get(obj.hSkel(j),'XData');
          ydata = get(obj.hSkel(j),'YData');
          xdata(k) = xy(i,1);
          ydata(k) = xy(i,2);
          set(obj.hSkel(j),'XData',xdata,'YData',ydata);
        end
      end

      
    end
    
    % XXX RENAME: refreshFullOccPtLocs
    function refreshOccludedPts(obj)
      % Set .hPts, .hPtsTxt, .hPtsOcc, .hPtsTxtOcc locs based on .tfOcc.
      %
      % .hPts, .hPtsTxt: 'Hide' occluded points. Non-occluded, no action.
      % .hPtsOcc, .hPtsTxtOcc: shown/hidden/positioned as appropriate
%       
%       if isempty(obj.hPtsOcc),
%         return;
%       end
      
      tf = obj.tfOcc;
      %assert(isvector(tf) && numel(tf)==obj.nPts);
      nOcc = nnz(tf);
      if nOcc>0
        if isempty(obj.hPtsOcc)
          % this cond is a proxy for lObj.showOccludedbox==false          
          
          % It's best to force-show the occ box now. The labelDB says there
          % are 1+ fully-occ points in this frame. Without revealing the 
          % occ box we cannot faithfully show the current label state.
          % Moreover the project is now known to contain fully-occluded
          % labels so the user will need the fully-occ box anyway.
          obj.labeler.setShowOccludedBox(true);
          obj.showOcc();
          
          % early-return b/c showOcc() calls/reenters this meth
          % (refreshOccludedPoints!)
          return
        end
        
        % Hide the 'regular' pts that are fully-occ
        obj.setPtsCoords(nan(nOcc,2),obj.hPts(tf),obj.hPtsTxt(tf));
      end
      
      if ~isempty(obj.hPtsOcc) 
        iOcc = find(tf);
        LabelCore.setPtsCoordsOcc([iOcc(:) ones(nOcc,1)],...
          obj.hPtsOcc(tf),obj.hPtsTxtOcc(tf));
        LabelCore.setPtsCoordsOcc(nan(obj.nPts-nOcc,2),...
          obj.hPtsOcc(~tf),obj.hPtsTxtOcc(~tf));
      end
    end
    
    function refreshPtMarkers(obj,varargin)
      % Update obj.hPts (and optionally, .hPtsOcc) Markers based on 
      % .tfEstOcc and .tfSel.
     
      [iPts,doPtsOcc] = myparse(varargin,...
        'iPts',1:obj.nPts,...
        'doPtsOcc',false);
      
      ppi = obj.ptsPlotInfo;
      ppitm = ppi.TemplateMode;

      hPoints = obj.hPts(iPts);
      tfSl = obj.tfSel(iPts);
      tfEO = obj.tfEstOcc(iPts);
      
      set(hPoints(tfSl & tfEO),'Marker',ppitm.SelectedOccludedMarker);
      set(hPoints(tfSl & ~tfEO),'Marker',ppitm.SelectedPointMarker);
      set(hPoints(~tfSl & tfEO),'Marker',ppi.OccludedMarker);
      set(hPoints(~tfSl & ~tfEO),'Marker',ppi.MarkerProps.Marker);
      
      if doPtsOcc && ~isempty(obj.hPtsOcc),
        hPointsOcc = obj.hPtsOcc(iPts);
        set(hPointsOcc(tfSl),'Marker',ppitm.SelectedPointMarker);
        set(hPointsOcc(~tfSl),'Marker',ppi.MarkerProps.Marker);
      end
    end
        
    function xy = getLabelCoords(obj)
      % rows matching .tfOcc are inf
      xy = nan(numel(obj.hPts),2);
      ish = ishandle(obj.hPts);
      xy(ish,:) = LabelCore.getCoordsFromPts(obj.hPts(ish));
      xy(obj.tfOcc,:) = inf;
    end
    
    function xy = getLabelCoordsI(obj,iPt)
      xy = LabelCore.getCoordsFromPts(obj.hPts(iPt));
    end
    
    function [tf,iSelected] = anyPointSelected(obj)
      iSelected = find(obj.tfSel,1);
      tf = ~isempty(iSelected);
    end
    
    function toggleSelectPoint(obj,iPts)
      tfSl = ~obj.tfSel(iPts);
      obj.tfSel(:) = false;
      obj.tfSel(iPts) = tfSl;
      obj.refreshPtMarkers('iPts',iPts,'doPtsOcc',true);
    end
    
    function clearSelected(obj,iExclude)
      tf = obj.tfSel;
      if exist('iExclude','var')>0
        tf(iExclude) = false;
      end
      iSelPts = find(tf);
      obj.toggleSelectPoint(iSelPts); %#ok<FNDSB>
    end
    
    function setLabelPosTagFromEstOcc(obj)
      lObj = obj.labeler;
      tfEO = obj.tfEstOcc;
      assert(~any(tfEO & obj.tfOcc));

      iPtEO = find(tfEO);
      iPtNO = find(~tfEO);
      lObj.labelPosTagSetI(iPtEO); %#ok<FNDSB>
      lObj.labelPosTagClearI(iPtNO); %#ok<FNDSB>
    end
    
  end
    
  methods (Static) % Utilities
    
    function assignLabelCoordsStc(xy,hPts,hTxt,txtOffset)
      % Simpler version of assignLabelCoords()
      %
      % xy: [nptsx2]
      % hPts: [npts]
      % hTxt: [npts]
      
      [npts,d] = size(xy);
      assert(d==2);
      assert(isequal(npts,numel(hPts),numel(hTxt)));
      
      % FullyOccluded
      tfOccld = any(isinf(xy),2);
      LabelCore.setPtsCoordsStc(xy(~tfOccld,:),...
        hPts(~tfOccld),hTxt(~tfOccld),txtOffset);      
      LabelCore.setPtsCoordsStc(nan(nnz(tfOccld),2),...
        hPts(tfOccld),hTxt(tfOccld),txtOffset);
    end
    
    function xy = getCoordsFromPts(hPts)
      x = get(hPts,{'XData'});
      y = get(hPts,{'YData'});
      x = cell2mat(x);
      y = cell2mat(y);
      xy = [x y];
    end
  end
  methods
    function setPtsCoords(obj,xy,hPts,hTxt)
      txtOffset = obj.labeler.labelPointsPlotInfo.TextOffset; % could use .ptsPlotInfo
      LabelCore.setPtsCoordsStc(xy,hPts,hTxt,txtOffset);
    end
    function redrawTextLabels(obj)
      % eg when text offset is updated
      txtOffset = obj.labeler.labelPointsPlotInfo.TextOffset; % could use .ptsPlotInfo
      
      h = obj.hPts;
      hT = obj.hPtsTxt;
      x = get(h,'XData');
      y = get(h,'YData');
      xy = [cell2mat(x(:)) cell2mat(y(:))];
      xyT = xy + txtOffset;
      %szassert(xy,[npts 2]);
      for i = 1:numel(hT)
        set(hT(i),'Position',[xyT(i,1) xyT(i,2) 1]);
      end
    end
  end
  methods (Static)
    function setPtsCoordsStc(xy,hPts,hTxt,txtOffset)
      %tic;
      nPoints = size(xy,1);
      assert(size(xy,2)==2);
      assert(isequal(nPoints,numel(hPts),numel(hTxt)));
      
      for i = 1:nPoints
        oldx = get(hPts(i),'XData');
        oldy = get(hPts(i),'YData');
        if isnan(oldx) && isnan(xy(i,1)) && isnan(oldy) && isnan(xy(i,2)),
          continue;
        end
        if oldx==xy(i,1) && oldy==xy(i,2),
          continue;
        end
        set(hPts(i),'XData',xy(i,1),'YData',xy(i,2));
        set(hTxt(i),'Position',[xy(i,1)+txtOffset xy(i,2)+txtOffset 1]);
      end
      %fprintf('LabelCore.setPtsCoordsStc: %f\n',toc);
    end
            
    function setPtsOffaxis(hPts,hTxt)
      % Set pts/txt to be "offscreen" ie positions to NaN.
      TXTOFFSET_IRRELEVANT = 1;
      LabelCore.setPtsCoordsStc(nan(numel(hPts),2),hPts,hTxt,...
        TXTOFFSET_IRRELEVANT);
    end
    
    function setPtsColor(hPts,hTxt,colors)
      assert(numel(hPts)==numel(hTxt));
      n = numel(hPts);
      assert(isequal(size(colors),[n 3]));
      for i = 1:n
        clr = colors(i,:);
        set(hPts(i),'Color',clr);
        set(hTxt(i),'Color',clr);
      end      
    end
    
    function setPtsCoordsOcc(xy,hPts,hTxt)
      LabelCore.setPtsCoordsStc(xy,hPts,hTxt,0.25);
    end
    
    function uv = transformPtsTrx(uv0,trx0,iFrm0,trx1,iFrm1)
      % uv0: npts x 2 array of points
      % trx0: scalar trx
      % iFrm0: absolute frame number for trx0
      % etc
      %
      % The points uv0 correspond to trx0 @ iFrm0. Compute uv that
      % corresponds to trx1 @ iFrm1, ie so that uv relates to trx1@iFrm1 in 
      % the same way that uv0 relates to trx0@iFrm0.
      %
      % Note: unlabeled -> unlabeled, occluded -> occluded, ie 
      %       NaN points -> NaN points, Inf points -> Inf points.
      
      assert(trx0.off==1-trx0.firstframe);
      assert(trx1.off==1-trx1.firstframe);
      
      tfFrmsInBounds = trx0.firstframe<=iFrm0 && iFrm0<=trx0.endframe && ...
                       trx1.firstframe<=iFrm1 && iFrm1<=trx1.endframe;
      if tfFrmsInBounds
        iFrm0 = iFrm0+trx0.off;
        xy0 = [trx0.x(iFrm0) trx0.y(iFrm0)];
        th0 = trx0.theta(iFrm0);

        iFrm1 = iFrm1+trx1.off;
        xy1 = [trx1.x(iFrm1) trx1.y(iFrm1)];
        th1 = trx1.theta(iFrm1);

        uv = transformPoints(uv0,xy0,th0,xy1,th1);
        tfinf = any(isinf(uv0),2); % [inf inf] rows in uv0 can be transformed into eg [inf nan] depending on angle
        uv(tfinf,:) = inf;
      else
        uv = uv0; % what else?
      end
    end
    
    function h = initSkeletonEdge(ax,i,ptsPlotInfo,color)
      
      if nargin < 4,
        color = [.7,.7,.7];
      end
      h = plot(ax(1),nan(2,1),nan(2,1),'-','Color',color,...
        'PickableParts','none','Tag',sprintf('LabelCore_Skel_%d',i),...
        'LineWidth',ptsPlotInfo.MarkerProps.LineWidth); 
      % Maybe should be using a dedicated skeleton LineWidth prop
      
    end
    
    function setSkelCoords(xy,tfOccld,hSkel,edges)
      
      xynan = xy;
      xynan(tfOccld,:) = nan;
      for i = 1:numel(hSkel),
        edge = edges(i,:);
        set(hSkel(i),'XData',xynan(edge,1),'YData',xynan(edge,2));
      end
      
    end
    
  end
  
end

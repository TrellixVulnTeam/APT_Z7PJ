classdef TrkFile < dynamicprops
  
  properties (Constant,Hidden)
    unsetVal = '__UNSET__';
  end
  
  properties
    pTrk = TrkFile.unsetVal;     % [npttrked x 2 x nfrm x ntgt], like labeledpos
    pTrkTS = TrkFile.unsetVal;   % [npttrked x nfrm x ntgt], liked labeledposTS
    pTrkTag = TrkFile.unsetVal;  % [npttrked x nfrm x ntgt] logical, like labeledposTag
    pTrkiPt = TrkFile.unsetVal;  % [npttrked]. point indices labeling rows of .pTrk*. If 
                                 %  npttrked=labeled.nLabelPoints, then .pTrkiPt=1:npttrked.
    pTrkFrm = TrkFile.unsetVal;  % [nfrm]. frames tracked
    pTrkiTgt = TrkFile.unsetVal; % [ntgt]. targets (1-based Indices) tracked

    pTrkFull = TrkFile.unsetVal; % [npttrked x 2 x nRep x nTrkFull], full tracking with replicates
    pTrkFullFT = TrkFile.unsetVal; % [nTrkFull x ncol] Frame-Target table labeling 4th dim of pTrkFull
    
    trkInfo % "user data" for tracker    
  end
  
  methods
    
    function obj = TrkFile(ptrk,varargin)
      % ptrk: must be supplied, to set .pTrk
      % varargin: p-v pairs for remaining props
      %
      % Example: tfObj = TrkFile(myTrkPos,'pTrkTS',myTrkTS);
      
      if nargin==0        
        return;
      end
      
      nArg = numel(varargin);
      for i=1:2:nArg
        prop = varargin{i};
        val = varargin{i+1};
        if ~isprop(obj,prop)
          warningNoTrace('Adding TrkFile property ''%s''.',prop);
          obj.addprop(prop);
        end         
        obj.(prop) = val;
      end
      
      [npttrk,d,nfrm,ntgt] = size(ptrk);
      if d~=2
        error('TrkFile:TrkFile','Expected d==2.');
      end
      obj.pTrk = ptrk;

      if isequal(obj.pTrkTS,TrkFile.unsetVal)
        obj.pTrkTS = zeros(npttrk,nfrm,ntgt);
      end
      validateattributes(obj.pTrkTS,{'numeric'},{'size' [npttrk nfrm ntgt]},'','pTrkTS');
      
      if isequal(obj.pTrkTag,TrkFile.unsetVal)
        obj.pTrkTag = false(npttrk,nfrm,ntgt);
      end
      validateattributes(obj.pTrkTag,{'logical'},...
        {'size' [npttrk nfrm ntgt]},'','pTrkTag');
      
      if isequal(obj.pTrkiPt,TrkFile.unsetVal)
        obj.pTrkiPt = 1:npttrk;
      end
      validateattributes(obj.pTrkiPt,{'numeric'},...
        {'vector' 'numel' npttrk 'positive' 'integer'},'','pTrkiPt');
      
      if isequal(obj.pTrkFrm,TrkFile.unsetVal)
        obj.pTrkFrm = 1:nfrm;
      end
      assert(issorted(obj.pTrkFrm));
      validateattributes(obj.pTrkFrm,{'numeric'},...
        {'vector' 'numel' nfrm 'positive' 'integer'},'','pTrkFrm');

      if isequal(obj.pTrkiTgt,TrkFile.unsetVal)
        obj.pTrkiTgt = 1:ntgt;
      end
      assert(issorted(obj.pTrkiTgt));
      validateattributes(obj.pTrkiTgt,{'numeric'},...
        {'vector' 'numel' ntgt 'positive' 'integer'},'','pTrkiTgt');
      
      tfUnsetTrkFull = isequal(obj.pTrkFull,TrkFile.unsetVal);
      tfUnsetTrkFullFT = isequal(obj.pTrkFullFT,TrkFile.unsetVal);
      assert(tfUnsetTrkFull==tfUnsetTrkFullFT);
      if tfUnsetTrkFull
        obj.pTrkFull = zeros(npttrk,2,0,0);
        obj.pTrkFullFT = table(nan(0,1),nan(0,1),'VariableNames',{'frm' 'iTgt'});
      end
      nRep = size(obj.pTrkFull,3);
      nFull = size(obj.pTrkFull,4);
      validateattributes(obj.pTrkFull,{'numeric'},...
        {'size' [npttrk 2 nRep nFull]},'','pTrkFull');
      assert(istable(obj.pTrkFullFT) && height(obj.pTrkFullFT)==nFull);
    end
    
    function save(obj,filename)
      % Saves to filename; ALWAYS OVERWRITES!!
      
      warnst = warning('off','MATLAB:structOnObject');
      s = struct(obj);
      warning(warnst);
      s = rmfield(s,'unsetVal'); %#ok<NASGU>      
      save(filename,'-mat','-struct','s');
    end
    
    function tbl = tableform(obj)
      p = obj.pTrk;
      [npts,d,nF,nTgt] = size(p);
      assert(d==2);
      p = reshape(p,[npts*d nF nTgt]);
      ptag = obj.pTrkTag;  
      pTS = obj.pTrkTS;
      pfrm = obj.pTrkFrm;
      ptgt = obj.pTrkiTgt;
      
      s = struct('frm',cell(0,1),'iTgt',[],'pTrk',[],'tfOcc',[],'pTrkTS',[]);
      for i=1:nF
      for j=1:nTgt
        pcol = p(:,i,j);
        tfOcccol = ptag(:,i,j);
        pTScol = pTS(:,i,j);
        if any(~isnan(pcol)) || any(tfOcccol)
          s(end+1,1).frm = pfrm(i); %#ok<AGROW>
          s(end).iTgt = ptgt(j);
          s(end).pTrk = pcol(:)';
          s(end).tfOcc = tfOcccol(:)';
          s(end).pTrkTS = pTScol(:)';
        end
      end
      end
      
      tbl = struct2table(s);
    end
    
    function mergePartial(obj1,obj2)
      % Merge trkfile into current trkfile. Doesn't merge .pTrkFull* fields 
      % (for now).
      %
      % obj2 TAKES PRECEDENCE when tracked frames/data overlap
      %
      % obj/obj2: trkfile objs. obj.pTrk and obj2.pTrk must have the same
      % size.
      
      assert(isscalar(obj1) && isscalar(obj2));
      %assert(isequal(size(obj.pTrk),size(obj2.pTrk)),'Size mismatch.');
      assert(isequal(obj1.pTrkiPt,obj2.pTrkiPt),'.pTrkiPt mismatch.');
      %assert(isequal(obj.pTrkiTgt,obj2.pTrkiTgt),'.pTrkiTgt mismatch.');
      
      if ~isempty(obj1.pTrkFull) || ~isempty(obj2.pTrkFull)
        warningNoTrace('.pTrkFull contents discarded.');
      end
      
      %frmComon = intersect(obj1.pTrkFrm,obj2.pTrkFrm);
      frmUnion = union(obj1.pTrkFrm,obj2.pTrkFrm);
      %iTgtComon = intersect(obj1.pTrkiTgt,obj2.pTrkiTgt);
      iTgtUnion = union(obj1.pTrkiTgt,obj2.pTrkiTgt);
      
      npttrk = numel(obj1.pTrkiPt);
      nfrm = numel(frmUnion);
      ntgt = numel(iTgtUnion);
     
      % Determine whether there is any overlap
      tfobj1HasRes = false(nfrm,ntgt);
      tfobj2HasRes = false(nfrm,ntgt);
      [~,locfrm1] = ismember(obj1.pTrkFrm,frmUnion);
      [~,locfrm2] = ismember(obj2.pTrkFrm,frmUnion);     
      [~,loctgt1] = ismember(obj1.pTrkiTgt,iTgtUnion);
      [~,loctgt2] = ismember(obj2.pTrkiTgt,iTgtUnion);          
      tfobj1HasRes(locfrm1,loctgt1) = true;
      tfobj2HasRes(locfrm2,loctgt2) = true;
      tfConflict = tfobj1HasRes & tfobj2HasRes;
      nfrmConflict = nnz(any(tfConflict,2));
      ntgtConflict = nnz(any(tfConflict,1));
      if nfrmConflict>0 % =>ntgtConflict>0
        warningNoTrace('TrkFiles share common results for %d frames, %d targets. Second trkfile will take precedence.',...
          nfrmConflict,ntgtConflict);
      end

      % init new pTrk, pTrkTS, pTrkTag; write results1, then results2 
      pTrk = nan(npttrk,2,nfrm,ntgt);
      pTrkTS = nan(npttrk,nfrm,ntgt);
      pTrkTag = nan(npttrk,nfrm,ntgt);            
      pTrk(:,:,locfrm1,loctgt1) = obj1.pTrk;      
      pTrk(:,:,locfrm2,loctgt2) = obj2.pTrk;
      pTrkTS(:,locfrm1,loctgt1) = obj1.pTrkTS;
      pTrkTS(:,locfrm2,loctgt2) = obj2.pTrkTS;
      pTrkTag(:,locfrm1,loctgt1) = obj1.pTrkTag;
      pTrkTag(:,locfrm2,loctgt2) = obj2.pTrkTag;
      obj1.pTrk = pTrk;
      obj1.pTrkTS = pTrkTS;
      obj1.pTrkTag = pTrkTag;      
      % Could use hlpMergePartial in the above 
      
      obj1.hlpMergePartial(obj2,'pTrk3d',[npttrk 3 nfrm ntgt],locfrm1,loctgt1,locfrm2,loctgt2);
      obj1.hlpMergePartial(obj2,'pTrkSingleView',[npttrk 2 nfrm ntgt],locfrm1,loctgt1,locfrm2,loctgt2);
      obj1.hlpMergePartial(obj2,'pTrkconf',[npttrk nfrm ntgt],locfrm1,loctgt1,locfrm2,loctgt2);
      obj1.hlpMergePartial(obj2,'pTrkconf_unet',[npttrk nfrm ntgt],locfrm1,loctgt1,locfrm2,loctgt2);
      obj1.hlpMergePartial(obj2,'pTrklocs_mdn',[npttrk 2 nfrm ntgt],locfrm1,loctgt1,locfrm2,loctgt2);
      obj1.hlpMergePartial(obj2,'pTrklocs_unet',[npttrk 2 nfrm ntgt],locfrm1,loctgt1,locfrm2,loctgt2);
      obj1.hlpMergePartial(obj2,'pTrkocc',[npttrk nfrm ntgt],locfrm1,loctgt1,locfrm2,loctgt2);

      %obj1.pTrkiPt = obj1.pTrkiPt; unchanged
      obj1.pTrkFrm = frmUnion;
      obj1.pTrkiTgt = iTgtUnion;
      obj1.pTrkFull = [];
      obj1.pTrkFullFT = [];
      
      if iscell(obj1.trkInfo)
        obj1.trkInfo{end+1} = obj2.trkInfo;
      else
        obj1.trkInfo = {obj1.trkInfo obj2.trkInfo};
      end
    end
    function hlpMergePartial(obj1,obj2,fld,valsz,locfrm1,loctgt1,locfrm2,loctgt2)
      % helper for mergePartial to handle additional/dynamic props
      %
      % mutates obj1.(fld)
      
      isprop1 = isprop(obj1,fld);
      isprop2 = isprop(obj2,fld);
      
      if isprop1 || isprop2
        val = nan(valsz);
        valndim = numel(valsz);
        if isprop1
          switch valndim
            case 3
              val(:,locfrm1,loctgt1) = obj1.(fld);
            case 4
              val(:,:,locfrm1,loctgt1) = obj1.(fld);
            otherwise
              assert(false);
          end
        end
        
        if isprop2
          switch valndim
            case 3
              val(:,locfrm2,loctgt2) = obj2.(fld);
            case 4              
              val(:,:,locfrm2,loctgt2) = obj2.(fld);
            otherwise
              assert(false);
          end
        end
        
        if ~isprop1
          obj1.addprop(fld);
        end        
        obj1.(fld) = val;
      end
    end
    
    function indexInPlace(obj,ipts,ifrms,itgts)
      % Subscripted-index a TrkFile *IN PLACE*. Your TrkFile will become
      % smaller and you will 'lose' data!
      % 
      % ipts: [nptsidx] actual/absolute landmark indices; will be compared 
      %   against .pTrkiPt. Can be -1 indicating "all available points".
      % ifrms: [nfrmsidx] actual frames; will be compared against .pTrkFrm.
      %   Can be -1 indicating "all available frames"
      % itgts: [ntgtsidx] actual targets; will be compared against
      % .pTrkiTgt. Can be -1 indicating "all available targets"
      %
      % Postconditions: All properties of TrkFile, including
      % dynamic/'extra' properties, are indexed appropriately to the subset
      % as specified by ipts, ifrms, itgts. 
      
      assert(isscalar(obj),'Obj must be a scalar Trkfile object.');
      
      if isequal(ipts,-1)
        ipts = obj.pTrkiPt;
      end
      if isequal(ifrms,-1)
        ifrms = obj.pTrkFrm;
      end
      if isequal(itgts,-1)
        itgts = obj.pTrkiTgt;
      end
      [tfpts,ipts] = ismember(ipts,obj.pTrkiPt);
      [tffrms,ifrms] = ismember(ifrms,obj.pTrkFrm);
      [tftgts,itgts] = ismember(itgts,obj.pTrkiTgt);
      if ~( all(tfpts) && all(tffrms) && all(tftgts) )
        error('All specified points, frames, and targets are not present in TrkFile.');
      end
      
      szpTrk = size(obj.pTrk); % [npts x 2 x nfrm x ntgt]
      szpTrkTS = size(obj.pTrkTS); % [npts x nfrm x ntgt]
      propsDim1Only = {'pTrkFull'};
      
      props = properties(obj);
      for p=props(:)',p=p{1};
        
        v = obj.(p);
        szv = size(v);
        
        if strcmp(p,'pTrkiPt')
          obj.(p) = v(ipts);
        elseif strcmp(p,'pTrkFrm')
          obj.(p) = v(ifrms);
        elseif strcmp(p,'pTrkiTgt')
          obj.(p) = v(itgts);
        elseif any(strcmp(p,propsDim1Only))
          szvnew = szv;
          szvnew(1) = numel(ipts);
          v = reshape(v,szv(1),[]);
          v = v(ipts,:);
          v = reshape(v,szvnew);
          obj.(p) = v;
        elseif isnumeric(v) || islogical(v)
          if isequal(szv,szpTrk)
            obj.(p) = v(ipts,:,ifrms,itgts);
          elseif isequal(szv,szpTrkTS)
            obj.(p) = v(ipts,ifrms,itgts);
          else
            warningNoTrace('Numeric property ''%s'' with unrecognized shape: %s',...
              p,mat2str(szv));
          end
        else
          % non-numeric prop, no action
        end
      end
    end
  end
  
  methods (Static)

    function trkfileObj = load(filename)
      s = load(filename,'-mat');
      s = TrkFile.modernizeStruct(s);
      if ~isfield(s,'pTrk')
        error('TrkFile:load',...
          'File ''%s'' is not a valid saved trkfile structure.',filename);
      end
      pTrk = s.pTrk;
      pvs = struct2pvs(rmfield(s,'pTrk'));
      trkfileObj = TrkFile(pTrk,pvs{:});
    end
    
    function trkfileObj = loadsilent(filename)
      % ignore fields of struct that aren't TrkFile props. For 3rd-party
      % generated Trkfiles
      s = load(filename,'-mat');
      s = TrkFile.modernizeStruct(s);      
      pTrk = s.pTrk;      
      
      mc = meta.class.fromName('TrkFile');
      propnames = {mc.PropertyList.Name}';
      fns = fieldnames(s);
      tfrecog = ismember(fns,propnames);
      %fnsrecog = fns(tfrecog);
      fnsunrecog = fns(~tfrecog);

      srecog = rmfield(s,fnsunrecog);
      pvs = struct2pvs(rmfield(srecog,'pTrk'));      
      trkfileObj = TrkFile(pTrk,pvs{:});
      
      for f=fnsunrecog(:)',f=f{1};
        trkfileObj.addprop(f);
        trkfileObj.(f) = s.(f);
      end      
    end

    function s = modernizeStruct(s)
      % s: struct loaded from trkfile saved to matfile
      if iscell(s.pTrkTag)
        s.pTrkTag = strcmp(s.pTrkTag,'occ');
      end
    end
    
  end
  
end

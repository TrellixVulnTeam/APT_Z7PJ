classdef DeepModelChainOnDisk < matlab.mixin.Copyable
  % DMCOD understands the filesystem structure of a deep model. This same
  % structure is used on both remote and local filesystems.
  %
  % DMCOD does know whether the model is on a local or remote filesystem 
  % via the .reader property. The .reader object is a delegate that knows 
  % how to actually read the (possibly remote) filesystem. This works fine 
  % for now future design unclear.
  
  properties
    rootDir % root/parent "Models" dir
    projID 
    netType % char(scalar DLNetType) -- (which is dumb, should prob just be scalar DLNetType
    view % 0-based
    modelChainID % unique ID for a training model for (projname,view). 
                 % A model can be trained once, but also train-augmented.
    trainID % a single modelID may be trained multiple times due to 
            % train-augmentation, so a single modelID may have multiple
            % trainID associated with it. Each (modelChainID,trainID) pair
            % has a unique associated stripped lbl.            
    restartTS % Training for each (modelChainID,trainID) can be killed and
              % restarted arbitrarily many times. This timestamp uniquely
              % identifies a restart
    trainType % scalar DLTrainType
    isMultiView = false; % whether this was trained with one call to APT_interface for all views
    iterFinal % final expected iteration    
    iterCurr % last completed iteration, corresponds to actual model file used
    nLabels % number of labels used to train
    
    reader % scalar DeepModelChainReader. used to update the itercurr; 
      % knows how to read the (possibly remote) filesys etc
      
    filesep ='/'; % file separator
      
    %aptRootUser % (optional) external/user APT code checkout root    
  end
  properties (Dependent)
    dirProjLnx
    dirNetLnx
    dirViewLnx  
    dirModelChainLnx
    dirTrkOutLnx
    dirAptRootLnx % loc of APT checkout (JRC)
    
    lblStrippedLnx % full path to stripped lbl file for this train session
    lblStrippedName % short filename 
    cmdfileLnx
    cmdfileName
    errfileLnx 
    errfileName
    trainLogLnx
    trainLogName
    viewName
    killTokenLnx
    killTokenName
    trainDataLnx    
    trainFinalModelLnx
    trainFinalModelName
    trainCurrModelLnx
    trainCurrModelName
    aptRepoSnapshotLnx
    aptRepoSnapshotName
    
    trainModelGlob
    
    isRemote
  end
  methods
    function v = get.dirProjLnx(obj)
      v = [obj.rootDir obj.filesep obj.projID];
    end
    function v = get.dirNetLnx(obj)
      v = [obj.rootDir obj.filesep obj.projID obj.filesep char(obj.netType)];
    end
    function v = get.viewName(obj)
      v = sprintf('view_%d',obj.view(1));
    end
    function v = get.dirViewLnx(obj)
      v = [obj.rootDir obj.filesep obj.projID obj.filesep char(obj.netType) obj.filesep sprintf('view_%d',obj.view)];
    end
    function v = get.dirModelChainLnx(obj)
      v = [obj.rootDir obj.filesep obj.projID obj.filesep char(obj.netType) obj.filesep sprintf('view_%d',obj.view) obj.filesep obj.modelChainID];
    end
    function v = get.dirTrkOutLnx(obj)
      v = [obj.rootDir obj.filesep obj.projID obj.filesep char(obj.netType) obj.filesep sprintf('view_%d',obj.view) obj.filesep obj.modelChainID obj.filesep 'trk'];
    end 
    function v = get.dirAptRootLnx(obj)
      v = [obj.rootDir obj.filesep 'APT'];
    end 
    function v = get.lblStrippedLnx(obj)      
      v = [obj.dirProjLnx obj.filesep obj.lblStrippedName];      
    end
    function v = get.lblStrippedName(obj)
      v = sprintf('%s_%s.lbl',obj.modelChainID,obj.trainID);
    end
    function v = get.cmdfileLnx(obj)      
      v = [obj.dirProjLnx obj.filesep obj.cmdfileName];      
    end
    function v = get.cmdfileName(obj)
      if obj.isMultiView
        v = sprintf('%s_%s.cmd',obj.modelChainID,obj.trainID);
      else
        v = sprintf('%sview%d_%s.cmd',obj.modelChainID,obj.view,obj.trainID);
      end
    end    
    function v = get.errfileLnx(obj)      
      v = [obj.dirProjLnx obj.filesep obj.errfileName];      
    end
    function v = get.errfileName(obj)
      if obj.isMultiView,
        v = sprintf('%s_%s.err',obj.modelChainID,obj.trainID);
      else
        v = sprintf('%sview%d_%s.err',obj.modelChainID,obj.view,obj.trainID);
      end
    end
    function v = get.trainLogLnx(obj)
      v = [obj.dirProjLnx obj.filesep obj.trainLogName];
    end
    function v = get.trainLogName(obj)
      switch obj.trainType
        case DLTrainType.Restart
          if obj.isMultiView,
            v = sprintf('%s_%s_%s%s.log',obj.modelChainID,obj.trainID,lower(char(obj.trainType)),obj.restartTS);
          else
            v = sprintf('%sview%d_%s_%s%s.log',obj.modelChainID,obj.view,obj.trainID,lower(char(obj.trainType)),obj.restartTS);
          end
        otherwise
          if obj.isMultiView,
            v = sprintf('%s_%s_%s.log',obj.modelChainID,obj.trainID,lower(char(obj.trainType)));
          else
            v = sprintf('%sview%d_%s_%s.log',obj.modelChainID,obj.view,obj.trainID,lower(char(obj.trainType)));
          end
      end
    end    
    function v = get.killTokenLnx(obj)
      if obj.isMultiView,
        v = [obj.dirProjLnx obj.filesep obj.killTokenName];
      else
        v = [obj.dirModelChainLnx obj.filesep obj.killTokenName];
      end
    end    
    function v = get.killTokenName(obj)
      switch obj.trainType
        case DLTrainType.Restart
          v = sprintf('%s_%s%s.KILLED',obj.trainID,lower(char(obj.trainType)),obj.restartTS);
        otherwise
          v = sprintf('%s_%s.KILLED',obj.trainID,lower(char(obj.trainType)));
      end
    end  
    function v = get.trainDataLnx(obj)
      v = [obj.dirModelChainLnx obj.filesep 'traindata.json'];
    end
    function v = get.trainFinalModelLnx(obj)
      v = [obj.dirModelChainLnx obj.filesep obj.trainFinalModelName];
    end
    function v = get.trainCurrModelLnx(obj)
      v = [obj.dirModelChainLnx obj.filesep obj.trainCurrModelName];
    end
    function v = get.trainFinalModelName(obj)
      switch obj.netType
        case {DLNetType.openpose DLNetType.leap} % this specificity prob belongs in DLNetType
          v = sprintf('deepnet-%d',obj.iterFinal);
        otherwise
          v = sprintf('deepnet-%d.index',obj.iterFinal);
      end
    end    
    function v = get.trainCurrModelName(obj)
      switch obj.netType
        case {DLNetType.openpose DLNetType.leap} % this specificity prob belongs in DLNetType
          v = sprintf('deepnet-%d',obj.iterCurr);
        otherwise
          v = sprintf('deepnet-%d.index',obj.iterCurr);
      end
    end
    function v = get.trainModelGlob(obj)
      switch obj.netType
        case {DLNetType.openpose DLNetType.leap} % this specificity prob belongs in DLNetType
          v = 'deepnet-*';
        otherwise
          v = 'deepnet-*.index';
      end
    end
    function v = get.aptRepoSnapshotLnx(obj)
      v = [obj.dirProjLnx obj.filesep obj.aptRepoSnapshotName];
    end
    function v = get.aptRepoSnapshotName(obj)
      v = sprintf('%s_%s.aptsnapshot',obj.modelChainID,obj.trainID);
    end
    function v = get.isRemote(obj)
      v = obj.reader.getModelIsRemote();
    end
  end
  methods (Access=protected)
    function obj2 = copyElement(obj)
      obj2 = copyElement@matlab.mixin.Copyable(obj);
      if ~isempty(obj.reader)
        obj2.reader = copy(obj.reader);
      end
    end
  end
  methods
    function obj = DeepModelChainOnDisk(varargin)
      for iprop=1:2:numel(varargin)
        obj.(varargin{iprop}) = varargin{iprop+1};
      end
    end
    function obj2 = copyAndDetach(obj)
      obj2 = copy(obj);
      obj2.prepareBg();
    end    
    function prepareBg(obj)
      % 'Detach' a DMC for use in bg processes
      % Typically you would deepcopy the DMC before calling this
      for i=1:numel(obj)
        if ~isempty(obj(i).reader)
          obj(i).reader.prepareBg();
        end
      end
    end
    function printall(obj)
      mc = metaclass(obj);
      props = mc.PropertyList;
      tf = [props.Dependent];
      propnames = {props(tf).Name}';
%       tf = cellfun(@(x)~isempty(regexp(x,'lnx$','once')),propnames);
%       propnames = propnames(tf);

      nobj = numel(obj);
      for iobj=1:nobj
        if nobj>1
          fprintf('### obj %d ###\n',iobj);
        end
        for iprop=1:numel(propnames)
          p = propnames{iprop};
          fprintf('%s: %s\n',p,obj(iobj).(p));
        end
      end
    end
    function lsProjDir(obj)
      obj.reader.lsProjDir(obj);
    end
    function lsModelChainDir(obj)
      obj.reader.lsModelChainDir(obj);
    end
    function lsTrkDir(obj)
      obj.reader.lsTrkDir(obj);
    end
    function g = modelGlobsLnx(obj)
      % filesys paths/globs of important parts/stuff to keep
      
      dmcl = obj.dirModelChainLnx;
      gnetspecific = DLNetType.modelGlobs(obj.netType,obj.iterCurr);
      gnetspecific = cellfun(@(x)[dmcl obj.filesep x],gnetspecific,'uni',0);
      
      g = { ...
        [obj.dirProjLnx obj.filesep sprintf('%s_%s*',obj.modelChainID,obj.trainID)]; ... % lbl
        [dmcl obj.filesep sprintf('%s*',obj.trainID)]; ... % toks, logs, errs
        };
      g = [g;gnetspecific(:)];
    end
    function mdlFiles = findModelGlobsLocal(obj)
      % Return all key/to-be-saved model files
      %
      % mdlFiles: column cellvec full paths
      
      globs = obj.modelGlobsLnx;
      mdlFiles = cell(0,1);
      for g = globs(:)',g=g{1}; %#ok<FXSET>
        if contains(g,'*')
          gP = fileparts(g);
          dd = dir(g);
          mdlFilesNew = {dd.name}';
          mdlFilesNew = cellfun(@(x) fullfile(gP,x),mdlFilesNew,'uni',0);
          mdlFiles = [mdlFiles; mdlFilesNew]; %#ok<AGROW>
        elseif exist(g,'file')>0
          mdlFiles{end+1,1} = g; %#ok<AGROW>
        end
      end      
    end
    
    function setFileSep(obj,fs)
      obj.filesep = fs;
    end
                 
    function tfSuccess = updateCurrInfo(obj)
      % Update .iterCurr by probing filesys
      
      assert(isscalar(obj));
      maxiter = obj.reader.getMostRecentModel(obj);
      obj.iterCurr = maxiter;
      tfSuccess = ~isnan(maxiter);
      
      if maxiter>obj.iterFinal
        warningNoTrace('Current model iteration (%d) exceeds specified maximum/target iteration (%d).',...
          maxiter,obj.iterFinal);
      end
    end
    
    % if nLabels not set, try to read it from the stripped lbl file
    function readNLabels(obj)
      if ~isempty(obj.lblStrippedLnx)
        s = load(obj.lblStrippedLnx,'preProcData_MD_frm','-mat');
        obj.nLabels = size(s.preProcData_MD_frm,1);
      end
    end
    
    % whether training has actually started
    function tf = isPartiallyTrained(obj)      
      tf = ~isempty(obj.iterCurr);      
    end
    
    function mirror2remoteAws(obj,aws)
      % Take a local DMC and mirror/upload it to the AWS instance aws; 
      % update .rootDir, .reader appropriately to point to model on remote 
      % disk.
      %
      % In practice for the client, this action updates the "latest model"
      % to point to the remote aws instance.
      %
      % PostConditions: 
      % - remote cachedir mirrors this model for key model files; "extra"
      % remote files not removed; identities of existing files not
      % confirmed but naming/immutability of DL artifacts makes this seem
      % safe
      % - .rootDir updated to remote cacheloc
      % - .reader update to AWS reader
      
      assert(isscalar(obj));
      assert(~obj.isRemote,'Model must be local in order to mirror/upload.');      

      succ = obj.updateCurrInfo;
      if ~succ
        error('Failed to determine latest model iteration in %s.',...
          obj.dirModelChainLnx);
      end
      fprintf('Current model iteration is %d.\n',obj.iterCurr);
     
      aws.checkInstanceRunning(); % harderrs if instance isn't running
      
      mdlFiles = obj.findModelGlobsLocal();
      pat = obj.rootDir;
      pat = regexprep(pat,'\\','\\\\');
      mdlFilesRemote = regexprep(mdlFiles,pat,DeepTracker.RemoteAWSCacheDir);
      mdlFilesRemote = FSPath.standardPath(mdlFilesRemote);
      nMdlFiles = numel(mdlFiles);
      netstr = char(obj.netType); % .netType is already a char I think but should be a DLNetType
      fprintf(1,'Upload/mirror %d model files for net %s.\n',nMdlFiles,netstr);
      descstr = sprintf('Model file: %s',netstr);
      for i=1:nMdlFiles
        src = mdlFiles{i};
        info = dir(src);
        filesz = info.bytes/2^10;
        dst = mdlFilesRemote{i};
        % We just use scpUploadOrVerify which does not confirm the identity
        % of file if it already exists. These model files should be
        % immutable once created and their naming (underneath timestamped
        % modelchainIDs etc) should be pretty/totally unique. 
        %
        % Only situation that might cause problems are augmentedtrains but
        % let's not worry about that for now.
        aws.scpUploadOrVerify(src,dst,sprintf('%s (%s), %d KB',descstr,info.name,round(filesz)),'destRelative',false); % throws
      end
      
      % if we made it here, upload successful
      
      obj.rootDir = DeepTracker.RemoteAWSCacheDir;
      obj.reader = DeepModelChainReaderAWS(aws);
    end
    
    function mirrorFromRemoteAws(obj,cacheDirLocal)
      % Inverse of mirror2remoteAws. Download/mirror model from remote AWS
      % instance to local cache.
      %
      % update .rootDir, .reader appropriately to point to model in local
      % cache.
      %
      % In practice for the client, this action updates the "latest model"
      % to point to the local cache.
      
      assert(isscalar(obj));      
      assert(obj.isRemote,'Model must be remote in order to mirror/download.');      
      
      aws = obj.reader.awsec2;
      [tfexist,tfrunning] = aws.inspectInstance();
      if ~tfexist,
        error('AWS EC2 instance %s could not be found.',aws.instanceID);
      end
      if ~tfrunning,
        [tfsucc,~,warningstr] = aws.startInstance();
        if ~tfsucc,
          error('Could not start AWS EC2 instance %s: %s',aws.instanceID,warningstr);
        end
      end      
      %aws.checkInstanceRunning(); % harderrs if instance isn't running
     
      succ = obj.updateCurrInfo;
      if ~succ
        error('Failed to determine latest model iteration in %s.',...
          obj.dirModelChainLnx);
      end
      fprintf('Current model iteration is %d.\n',obj.iterCurr);
     
            
      mdlFilesRemote = aws.remoteGlob(obj.modelGlobsLnx);
      cacheDirLocalEscd = regexprep(cacheDirLocal,'\\','\\\\');
      mdlFilesLcl = regexprep(mdlFilesRemote,obj.rootDir,cacheDirLocalEscd);
      nMdlFiles = numel(mdlFilesRemote);
      netstr = char(obj.netType); % .netType is already a char now
      fprintf(1,'Download/mirror %d model files for net %s.\n',nMdlFiles,netstr);
      for i=1:nMdlFiles
        fsrc = mdlFilesRemote{i};
        fdst = mdlFilesLcl{i};
        % See comment in mirror2RemoteAws regarding not confirming ID of
        % files-that-already-exist
        aws.scpDownloadOrVerifyEnsureDir(fsrc,fdst,...
          'sysCmdArgs',{'dispcmd' true 'failbehavior' 'err'}); % throws
      end
      
      % if we made it here, download successful
      
      obj.rootDir = cacheDirLocal;
      obj.reader = DeepModelChainReaderLocal();
    end
       
  end
  
  
  methods (Static)
    
    function iter = getModelFileIter(filename)
      
      iter = regexp(filename,'deepnet-(\d+)','once','tokens');
      if isempty(iter),
        iter = [];
        return;
      end
      iter = str2double(iter{1});
      
    end
    
  end
end
    
  
  
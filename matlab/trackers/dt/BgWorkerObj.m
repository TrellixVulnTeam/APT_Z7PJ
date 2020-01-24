classdef BgWorkerObj < handle
  % Object deep copied onto BG worker. To be used with
  % BGWorkerContinuous
  % 
  % Responsibilities:
  % - Poll filesystem for updates
  % - Be able to read/parse the current state on disk
  
  % Class diagram 20191223
  % Only leaf/concrete classes Bg{Train,Track}WorkerObj{BEtype} are 
  % instantiated.
  % 
  % BgWorkerObj
  % BgTrainWorkerObj < BgWorkerObj
  % BgTrackWorkerObj < BgWorkerObj
  % BgWorkerObjLocalFilesys < BgWorkerObj
  %   BgWorkerObjDocker < BgWorkerObjLocalFilesys  
  %   BgWorkerObjBsub < BgWorkerObjLocalFilesys
  %   BgWorkerObjConda < BgWorkerObjLocalFilesys  
  % BgWorkerObjAWS < BgWorkerObj
  %
  % Train concrete classes
  % BgTrainWorkerObjDocker < BgWorkerObjDocker & BgTrainWorkerObj  
  % BgTrainWorkerObjConda < BgWorkerObjConda & BgTrainWorkerObj
  % BgTrainWorkerObjBsub < BgWorkerObjBsub & BgTrainWorkerObj
  % BgTrainWorkerObjAWS < BgWorkerObjAWS & BgTrainWorkerObj
  %
  % Track concrete classes
  % BgTrackWorkerObjDocker < BgWorkerObjDocker & BgTrackWorkerObj  
  % BgTrackWorkerObjConda < BgWorkerObjConda & BgTrackWorkerObj  
  % BgTrackWorkerObjBsub < BgWorkerObjBsub & BgTrackWorkerObj  
  % BgTrackWorkerObjAWS < BgWorkerObjAWS & BgTrackWorkerObj 
  
  properties
    nviews
    dmcs % [nview] DeepModelChainOnDisk array  
  end
  
  methods (Abstract)
    tf = fileExists(obj,file)
    tf = errFileExistsNonZeroSize(obj,errFile)
    s = fileContents(obj,file)
    killFiles = getKillFiles(obj)
    [tf,warnings] = killProcess(obj)
    sRes = compute(obj)
  end
  
  methods
    
    function obj = BgWorkerObj(nviews,dmcs,varargin)
      if nargin == 0,
        return;
      end
      obj.nviews = nviews;
      assert(isa(dmcs,'DeepModelChainOnDisk') && ((numel(dmcs)==1 && isempty(dmcs.view)) || numel(dmcs)==nviews));
      obj.dmcs = dmcs;
      obj.reset();
    end
    
    function logFiles = getLogFiles(obj)
      fprintf('Using BgWorkerObj.getLogFiles ... maybe shouldn''t happen.\n');
      logFiles = {};
    end
    
    function errFile = getErrFile(obj)
      errFile = {};
    end

    function reset(obj)
      
    end
       
    function printLogfiles(obj) % obj const
      logFiles = obj.getLogFiles();
      logFiles = unique(logFiles);
      logFileContents = cellfun(@(x)obj.fileContents(x),logFiles,'uni',0);
      BgWorkerObj.printLogfilesStc(logFiles,logFileContents)
    end

    function ss = getLogfilesContent(obj) % obj const
      logFiles = obj.getLogFiles();
      logFileContents = cellfun(@(x)obj.fileContents(x),logFiles,'uni',0);
      ss = BgWorkerObj.getLogfilesContentStc(logFiles,logFileContents);
    end
    
    function [tfEFE,errFile] = errFileExists(obj) % obj const
      errFile = obj.getErrFile();
      if isempty(errFile),
        tfEFE = false;
      else
        tfEFE = any(cellfun(@(x) obj.errFileExistsNonZeroSize(x),errFile));
      end
    end
    
    function ss = getErrorfileContent(obj) % obj const
      errFiles = obj.getErrFile();
      errFileContents = cellfun(@(x)obj.fileContents(x),errFiles,'uni',0);
      ss = BgWorkerObj.getLogfilesContentStc(errFiles,errFileContents);
      %ss = strsplit(obj.fileContents(errFile),'\n');
    end
    
    function tfLogErrLikely = logFileErrLikely(obj,file) % obj const
      tfLogErrLikely = obj.fileExists(file);
      if tfLogErrLikely
        logContents = obj.fileContents(file);
        tfLogErrLikely = ~isempty(regexpi(logContents,'exception','once'));
      end
    end
    
    function dispModelChainDir(obj)
      for ivw=1:obj.nviews
        dmc = obj.dmcs(ivw);
        cmd = sprintf('ls -al "%s"',dmc.dirModelChainLnx);
        fprintf('### View %d: %s\n',ivw,dmc.dirModelChainLnx);
        system(cmd);
        fprintf('\n');
      end
    end
    
    function dispTrkOutDir(obj)
      for ivw=1:obj.nviews
        dmc = obj.dmcs(ivw);
        cmd = sprintf('ls -al "%s"',dmc.dirTrkOutLnx);
        fprintf('### View %d: %s\n',ivw,dmc.dirTrkOutLnx);
        system(cmd);
        fprintf('\n');
      end
    end
    
%     function backEnd = getBackEnd(obj)
%       
%       backEnd = obj.dmcs.backEnd;
%       
%     end
    
    function res = queryAllJobsStatus(obj)
      
      res = 'Not implemented.';
      
    end
    
    function res = queryMyJobsStatus(obj)
      
      res = 'Not implemented.';
      
    end
   
    function res = getIsRunning(obj)
      
      % not implemented
      res = true;
    
    end
    
  end
  
  methods (Static)
    
    function printLogfilesStc(logFiles,logFileContents)
      % Print logs for all views
      
      for ivw=1:numel(logFiles)
        logfile = logFiles{ivw};
        fprintf(1,'\n### Job %d:\n### %s\n\n',ivw,logfile);
        disp(logFileContents{ivw});
      end
    end

    function ss = getLogfilesContentStc(logFiles,logFileContents)
      % Print logs for all views

      ss = {};
      for ivw=1:numel(logFiles)
        logfile = logFiles{ivw};
        ss{end+1} = sprintf('### Job %d:',ivw); %#ok<AGROW>
        ss{end+1} = sprintf('### %s',logfile); %#ok<AGROW>
        ss{end+1} = ''; %#ok<AGROW>
        ss = [ss,strsplit(logFileContents{ivw},'\n')]; %#ok<AGROW>
      end
    end

    
  end
  
end
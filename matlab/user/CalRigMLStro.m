classdef CalRigMLStro < CalRigZhang2CamBase
    
  % Note: ML Stro Calib App requires all ims/views to have the same size.
  
  properties
    nonMLinit = false; % if true, obj is not initialized from MATLAB stereo calibration
    calSess % scalar Session from ML Stro calibration; or if .nonMLinit, scalar struct mirroring calSession object
    
    eplineComputeMode = 'caltech'; % one of 'caltech' or 'zray'
  end
  properties (Dependent)
    stroParams
  end
  
  % Extrinsics
  properties (Dependent,Hidden)
    RLR
    RRL
    TLR
    TRL
  end
  %Intrinsics
  properties
    int % dups state in calSess, but non-Dependent for perf
  end

  methods
    function v = get.stroParams(obj)
      v = obj.calSess.CameraParameters;
    end
    function R = get.RLR(obj)
      R = obj.stroParams.RotationOfCamera2'; 
      % ML defines R, T by 
      %[x y z] = [X Y Z]*R + t
      
      %R = obj.RRL';
    end
    function R = get.RRL(obj)
      R = obj.RLR';
    end
    function T = get.TLR(obj)
      T = obj.stroParams.TranslationOfCamera2(:);
      %T = -obj.RRL'*obj.TRL;
    end
    function T = get.TRL(obj)
      T = -obj.RLR'*obj.TLR;
    end
    function s = getInt(obj)
      sp = obj.stroParams;
      
      s1 = struct();
      [s1.fc,s1.cc,s1.kc,s1.alpha_c] = ...
        CalRigMLStro.camParams2Intrinsics(sp.CameraParameters1);
      s2 = struct();
      [s2.fc,s2.cc,s2.kc,s2.alpha_c] = ...
        CalRigMLStro.camParams2Intrinsics(sp.CameraParameters2);
      
      s = struct(obj.viewNames{1},s1,obj.viewNames{2},s2);
    end
  end
  
  methods
    
    function obj = CalRigMLStro(calSess,varargin)
      % obj = CalRigMLStro(calSess) 
      % calSess: one of:
      %   1. a char filename for saved result from ML Stereo Calib App; 
      %   2. the ML calibration Session object saved therein; 
      %   3. char filename for APT-style rig config/param YAML file;
      %   4. a YAML struct for such YAML contents
      
      offerSave = myparse(varargin, ...
        'offerSave',true...
        );
      
      isYamlRig = false;
      if ischar(calSess)
        [~,~,ext] = fileparts(calSess);
        switch ext
          case '.yaml'
            s = ReadYaml(calSess);
            calSessObj = CalRigMLStro.rigYaml2CalSess(s);
            isYamlRig = true;
          case '.mat'
            s = load(calSess,'-mat','calibrationSession');
            calSessObj = s.calibrationSession;
        end
      elseif isa(calSess,'vision.internal.calibration.tool.Session')
        calSessObj = calSess;
      elseif isstruct(calSess) && isfield(calSess,'NumCameras')
        calSessObj = CalRigMLStro.rigYaml2CalSess(calSess);
        isYamlRig = true;
      else
        error('Input argument must be a MATLAB Stereo Calibration Session.');
      end
      
      obj.calSess = calSessObj;
      obj.nonMLinit = isYamlRig;
      obj.int = obj.getInt();

      obj.eplineComputeMode = 'caltech';
      %obj.autoCalibrateProj2NormFuncTol();
      obj.proj2NormFuncTol = nan; % AL20220302 no longer used

      if ~isYamlRig
        obj.autoCalibrateEplineZrange();
        obj.runDiagnostics();
      end
      
      if offerSave
        if ischar(calSess)
          startpwd = fileparts(calSess);
        else
          startpwd = pwd;
        end        
        [fname,pname] = uiputfile('*.mat',...
          'Save APT calibration object file.',startpwd);
        if isequal(fname,0)
          % user cancelled. obj created but not saved.
        else
          fname = fullfile(pname,fname);
          save(fname,'-mat','obj');
          fprintf('Saved file %s.\n',fname);
        end
      end
    end
    
    % AL20220302: currently unused, see .projected2normalized now relying
    % on MATLAB/vision API for undistorting (removing nonlinearities)
    function autoCalibrateProj2NormFuncTol(obj,varargin)
      % Automatically set .proj2NormFuncTol by "round-tripping" calibration
      % points through projected2normalized/normalized2projected.
      %
      % normalized2projected takes a point in normalized coordinates for a
      % camera and projects onto the final image by recentering about the
      % principal point, applying zoom/skew, and applying distortions.
      % The distortions are highly nonlinear closed-form expressions.
      %
      % projected2normalized inverts normalized2projected numerically,
      % using eg lsqnonlin. This inversion/optimization will have a functol
      % or other threshold controlling how precise the inversion must be.
      % This method/inversion is necesary for computing EP lines (as of 18b
      % there does not appear to be a MATLAB CV toolbox library fcn
      % available; MATLAB's triangulate() does its own nonlinear
      % inversion.)
      %
      % We auto-calibrate this threshold by requiring that the round-trip
      % error is less than calPtL2RTerr (optionally supplied).
      
      calPtL2RTerr = myparse(varargin,...
        'calPtL2RTerr',1/8 ... % in pixels
        );
      
      cs = obj.calSess;
      [bs,calpts] = CalRigMLStro.getCalSessionBoardSet(cs);
      %calpts = bs.BoardPoints; % ipt, x/y, ipat, ivw
      [npts,d,npat,nvw] = size(calpts);
      calpts = permute(calpts,[1 3 2 4]);
      calpts = reshape(calpts,[npts*npat d nvw]);
      
      fprintf(1,'\nAuto-calibrating .projected2normalized funcTol with %d calibration points.\n',...
        npts*npat);
      fprintf(1,'Required round-trip L2 accuracy: %.3f px.\n',calPtL2RTerr);
      
      functol = 1e-6;
      
      % FUTURE: factor core into CalRigZhang2CamBase
      calptsRT = nan(size(calpts));
      while 1
        fprintf(1,' ... trying funcTol=%.3g\n',functol);
        
        for icam=1:2
          calptsNorm = arrayfun(@(i)obj.projected2normalized(calpts(i,:,icam)',icam,'functol',functol),...
            1:npts*npat,'uni',0);
          calptsNorm = cat(2,calptsNorm{:});
          calptsRT(:,:,icam) = obj.normalized2projected(calptsNorm,icam)';
        end
        
        d = calpts-calptsRT;
        err = squeeze(sqrt(sum(d.^2,2)));
        szassert(err,[npts*npat nvw]);
        maxerr = max(err);
        
        fprintf(' ... max roundtrip err, view1: %.3g. view2: %.3g.\n',...
          maxerr(1),maxerr(2));
        if all(maxerr<calPtL2RTerr)
          fprintf(' ... SUCCESS! Setting .proj2NormFuncTol to %.3g.\n',functol);
          obj.proj2NormFuncTol = functol;
          break;
        elseif functol < 1e-13
          fprintf(' ... STOPPING. Setting .proj2NormFuncTol to %.3g.\n',functol);
          obj.proj2NormFuncTol = functol;
          break;
        else
          functol = functol/2;
        end
      end
    end
    
    function autoCalibrateEplineZrange(obj,varargin)
      % Automatically set .eplineZrange by computing EPlines from view1->2
      % and vice versa at i) the four corners and ii) center of views:
      %
      % - The start/end of the zrange must fully accomodate all EPlines
      %
      % - dz is chosen so that the average spacing discretization of
      % EPlines is ~1px (see optional param)
      %
      % Note, the bulk of computational expense for EP-line computation is
      % the nonlinear inversion in projected2normalized(). Using a zrange
      % that is too big or too fine shouldn't hurt much. This
      % auto-calibration may still be handy however.
      
      [eplineDxy,zrangeWidthTitrationFac] = myparse(varargin,...
        'eplineDxy',1, ... % in pixels
        'zrangeWidthTitrationFac',1.5 ... % increase range of zwidth by this much every step
        );
      
      cs = obj.calSess;
      [bs,calpts] = CalRigMLStro.getCalSessionBoardSet(cs);
      %calpts = bs.BoardPoints; % ipt, x/y, ipat, ivw
      [npts,d,npat,nvw] = size(calpts);
      calpts = permute(calpts,[1 3 2 4]);
      calpts = reshape(calpts,[npts*npat d nvw]);
      roi = [1 bs.ImageSize(2) 1 bs.ImageSize(1)];
      
      fprintf(1,'\nAuto-calibrating .eplineZrange. Imagesize is: %s.\n',...
        mat2str(bs.ImageSize));
      
      fprintf(1,'Starting with %d calpts.\n',npts*npat);
      
      % Start with calpts.
      % Initial z-range: fits
      Xcalpts1 = obj.stereoTriangulate(calpts(:,:,1)',calpts(:,:,2)');
      Xcalpts2 = obj.camxform(Xcalpts1,[1 2]);
      zrange0 = [ min(Xcalpts1(3,:)) max(Xcalpts1(3,:));...
                  min(Xcalpts2(3,:)) max(Xcalpts2(3,:)) ];
      % zrange: ivw, zmin/zmax
      
      % Auto-calibrate dz so that the spacing of EPline pts in each view is
      % ~eplineDxy.
      dz = 1;
      zrange1 = zrange0(1,1):dz:zrange0(1,2);
      zrange2 = zrange0(2,1):dz:zrange0(2,2);
      fprintf('Choosing dz. Starting with dz=%.3f.\n',dz);
      epdmu = obj.calculateMeanEPlineSpacing(calpts,roi,zrange1,zrange2);
      fprintf('Mean spacing in EP lines in view1/2: %s.\n',mat2str(epdmu));
      epdxy = mean(epdmu);
      dz = dz * eplineDxy/epdxy;
      fprintf('Selected dz=%.3f.\n',dz);
      zrange1 = zrange0(1,1):dz:zrange0(1,2);
      zrange2 = zrange0(2,1):dz:zrange0(2,2);
      epdmu = obj.calculateMeanEPlineSpacing(calpts,roi,zrange1,zrange2);
      fprintf('New mean spacing in EP lines in view1/2: %s.\n',mat2str(epdmu));
      
      % Autocalibrate zrange by expanding the zrange until the number of
      % in-bounds points stops changing.
      zRangeWidthCtr = [diff(zrange0,1,2) mean(zrange0,2)];
      % zRangeWidthCtr(ivw,1) is width
      % zRangeWidthCtr(ivw,2) is center
      
      % four corners and center
      testpts = [roi([1 3]); roi([1 4]); roi([2 4]); roi([2 3]); ...
                 mean(roi([1 2])) mean(roi([3 4]))];
      ntestpts = size(testpts,1);
      fprintf(1,'Selecting zrange with %d test points.\n',ntestpts);
      
      ENOUGHPTS = 2e3;
      NVW = 2;      
      %nInBounds = zeros(ntestpts,NVW);
      obj.eplineZrange = cell(1,NVW);
      for ivw=1:NVW
        fprintf(1,'Computing zrange for view %d...\n',ivw);
        nInBounds = -ones(ntestpts,1);
        while 1
          zrangelims = zRangeWidthCtr(ivw,2) + 0.5*zRangeWidthCtr(ivw,1)*[-1 1];
          zrangelims = max(zrangelims,0);
          % want zrangelims to be integer multiples of dz. That way, as 
          % range is expanded, zrange are precise successive supersets to
          % avoid edge effects where nInBounds has spurious changes by +/-1 
          zrangelims = round(zrangelims/dz)*dz;
          zrange = zrangelims(1):dz:zrangelims(2);

          fprintf('... zrange (n=%d): %s.\n',numel(zrange),mat2str(zrange([1 end])));

          nInBoundsNew = nan(ntestpts,1);
          ivwother = 3-ivw;
          for ipt=1:ntestpts
            [~,~,~,tfOOB] = ...
              obj.computeEpiPolarLine(ivw,testpts(ipt,:)',ivwother,roi,'z1range',zrange);
            nInBoundsNew(ipt) = nnz(~tfOOB);
          end

          disp(nInBoundsNew);

          tfPtIsGood = nInBounds==nInBoundsNew | nInBoundsNew>ENOUGHPTS;
          % AL 20220302 second condition is required bc in some cases
          % nInBoundsNew will continue to grow without bound; for example
          % with both cameras close to each other and axis-aligned, viewing 
          % a target together "in parallel". In this case, each increase
          % in zrange will continually add points to the EP line (almost
          % all of which will lie on top of each other).
          if all(tfPtIsGood)
            % All pts have either saturated by being unchanging, or their
            % EPlines exceed ENOUGHPTS.
            fprintf('SUCCESS! zrange found for view %d.\n',ivw);
            break;
          end

          zRangeWidthCtr(ivw,1) = zRangeWidthCtr(ivw,1)*zrangeWidthTitrationFac;
          nInBounds = nInBoundsNew;
        end
        
        obj.eplineZrange{ivw} = zrange;
      end
    end
    
    function epdmu = calculateMeanEPlineSpacing(obj,calpts,roi,zrange1,zrange2)
      % calpts: [nx2x2]. i,x/y,vw
      %
      % epdmu: [2] mean EP line spacing in vw 1/2

      n = size(calpts,1);
      szassert(calpts,[n 2 2]);
      
      epdmu = nan(n,2);
      for i=1:n
        [ep12x,ep12y] = ...
          obj.computeEpiPolarLine(1,calpts(i,:,1)',2,roi,'z1range',zrange1);
        [ep21x,ep21y] = ...
          obj.computeEpiPolarLine(2,calpts(i,:,2)',1,roi,'z1range',zrange2);
        
        ep12dxy = diff([ep12x ep12y],1,1);
        ep21dxy = diff([ep21x ep21y],1,1);
        ep12d = sqrt(sum(ep12dxy.^2,2));
        ep21d = sqrt(sum(ep21dxy.^2,2));
        epdmu(i,1) = nanmean(ep12d);
        epdmu(i,2) = nanmean(ep21d);
      end
      epdmu = mean(epdmu);
    end
    
    function runDiagnostics(obj)
      obj.diagnosticsTriangulationRP();
      obj.diagnosticsProjection();
      obj.diagnosticsUndistort();
      obj.diagnosticsEPlines();
    end
    
    function hFig = diagnosticsTriangulationRP(obj,varargin)
      % This diagnostic compares ML's triangulate() vs our
      % stereoTriangulation. Implicitly, this also compares undistortPoints
      % vs projected2normalized, and worldToImage vs normalized2projected.
      [showplots,wbObj] = myparse(varargin,...
        'showplots',true,...
        'wbObj',[]...
        );
      tfWB = ~isempty(wbObj);
      
      fprintf(1,'\nRunning triangulation/reprojection diagnostics.\n');
      
      % compute RP err using ML lib fcns
      
      cs = obj.calSess;
      sp = obj.stroParams;
      %       cp1 = sp.CameraParameters1;
      %       cp2 = sp.CameraParameters2;
      [bs,calpts] = CalRigMLStro.getCalSessionBoardSet(cs);
      
      %calpts = bs.BoardPoints; % ipt, x/y, ipat, ivw
      [npts,d,npat,nvw] = size(calpts);
      calpts = permute(calpts,[1 3 2 4]);
      calpts = reshape(calpts,[npts*npat d nvw]);
      
      % ML triangulate()
      [X1ml,~,~,e1RPml,e2RPml] = ...
        obj.stereoTriangulate(calpts(:,:,1)',calpts(:,:,2)');
      eRPml = [e1RPml(:) e2RPml(:)];
      szassert(eRPml,[npts*npat 2]);
      
      % using CalRigZhang2CamBase
      X1base = nan(3,npts*npat);
      X2base = nan(3,npts*npat);
      if tfWB
        wbObj.startPeriod('stereo triangulation','shownumden',true,...
          'denominator',ntot);
      end
      for i=1:npts*npat
        if tfWB
          wbObj.updateFracWithNumDen(i);
        end
        [X1base(:,i),X2base(:,i)] = ...
          obj.stereoTriangulateBase(calpts(i,:,1)',calpts(i,:,2)',1,2);
      end
      xn1 = X1base(1:2,:)./X1base(3,:);
      xn2 = X2base(1:2,:)./X2base(3,:);
      xpRPbase(:,:,1) = obj.normalized2projected(xn1,1);
      xpRPbase(:,:,2) = obj.normalized2projected(xn2,2);
      xpRPbase = permute(xpRPbase,[2 1 3]);
      eRPbase = squeeze(sqrt(sum((calpts-xpRPbase).^2,2)));
      szassert(eRPbase,[npts*npat 2]);
      
      eRPml = reshape(eRPml,[npts npat 2]);
      eRPbase = reshape(eRPbase,[npts npat 2]);
      errX1 = sqrt(sum((X1ml-X1base).^2,1));
      szassert(errX1,[1 npts*npat]);
      errX1 = errX1(:);
      l2distX1pts12 = sqrt(sum( diff(X1ml(:,1:2),1,2).^2 ));
        % 3D distance from pts 1 and 2 (neighboring checkerboard pts) in
        % pattern 1
      
      eRPmlMn = mean(eRPml(:));
      eRPmlMdn = median(eRPml(:));
      eRPmlMx = max(eRPml(:));
      eRPbaseMn = mean(eRPbase(:));
      eRPbaseMdn = median(eRPbase(:));
      eRPbaseMx = max(eRPbase(:));
      errX1mn = mean(errX1);
      errX1md = median(errX1);
      errX1mx = max(errX1);
      
      if showplots
        hFig = figure('Name','Stereo Triangulation/Reprojection diagnostics');
        axs = mycreatesubplots(2,2,[.15 .1;.15 .1]);
        
        axes(axs(1,1));
        histogram(errX1);
        grid on;
        tstr = sprintf('3D err, %d stereo-triangulated pts',numel(errX1));
        title(tstr,'fontweight','bold');
        xlabel('3D l2 err (probably mm)','interpreter','none');
        ylabel('count');
        fprintf('3D err, %d stereo-tri''d points. Mean/Mdn/Max: %.3g/%.3g/%.3g\n',...
          numel(errX1),errX1mn,errX1md,errX1mx);
        fprintf('  for comparison, 3D distance between neighboring checkerboard pts: %.3g\n',...
          l2distX1pts12);
        
        
        ax = axs(1,2);
        showReprojectionErrors(sp,'parent',ax);
        title('Mean Reprojection error from showReprojectionErrors()','interpreter','none');
        grid on;
        fprintf('RP err, from calibration session (px). Mean: %.3f\n',...
          cs.CameraParameters.MeanReprojectionError);
        
        axes(axs(2,1));
        eRPmlPerIm = squeeze(mean(eRPml,1));
        szassert(eRPmlPerIm,[npat 2]);
        hbar = bar(eRPmlPerIm,'grouped');
        hold on;
        plot([1 npat],[eRPmlMn eRPmlMn],'k-');
        legend(hbar,{'cam1' 'cam2'});
        grid on;
        title('Mean RP err per image, using ML lib fcns','fontweight','bold');
        xlabel('Cal image pair');
        ylabel('Mean RP err (px)');
        fprintf('RP err, ML lib fcns (px). Mean/Mdn/Max: %.3f/%.3f/%.3f\n',...
          eRPmlMn,eRPmlMdn,eRPmlMx);
        
        axes(axs(2,2));
        eRPbasePerIm = squeeze(mean(eRPbase,1));
        szassert(eRPbasePerIm,[npat 2]);
        hbar = bar(eRPbasePerIm,'grouped');
        hold on;
        plot([1 npat],[eRPbaseMn eRPbaseMn],'k-');
        legend(hbar,{'cam1' 'cam2'});
        grid on;
        title('Mean RP err per image, using our fcns','fontweight','bold');
        xlabel('Cal image pair');
        ylabel('Mean RP err (px)');
        fprintf('RP err, our fcns (px). Mean/Mdn/Max: %.3f/%.3f/%.3f\n',...
          eRPbaseMn,eRPbaseMdn,eRPbaseMx);
        
        linkaxes(axs(2:4));
      end
    end
    
    function diagnosticsProjection(obj)
      % Compare ML worldToImage to our normalized2projected
      
      fprintf(1,'\nRunning projection diagnostics.\n');

      cs = obj.calSess;
      % sp = obj.stroParams;
      %       cp1 = sp.CameraParameters1;
      %       cp2 = sp.CameraParameters2;
      [bs,calpts] = CalRigMLStro.getCalSessionBoardSet(cs);
      
      %calpts = bs.BoardPoints; % ipt, x/y, ipat, ivw
      [npts,d,npat,nvw] = size(calpts);
      calpts = permute(calpts,[1 3 2 4]);
      calpts = reshape(calpts,[npts*npat d nvw]);
      
      [X1ml,xp1ml,xp2ml] = ...
        obj.stereoTriangulate(calpts(:,:,1)',calpts(:,:,2)');            
      X2ml = obj.camxform(X1ml,[1 2]);
      
      im1norm = X1ml([1 2],:)./X1ml(3,:); % normalize
      im2norm = X2ml([1 2],:)./X2ml(3,:); % normalize      
      xp1base = obj.normalized2projected(im1norm,1);
      xp2base = obj.normalized2projected(im2norm,2);
      
      xpml = cat(3,xp1ml,xp2ml); 
      xpbase = cat(3,xp1base,xp2base);
      szassert(xpml,[2 npts*npat 2]);
      szassert(xpbase,[2 npts*npat 2]);

      err = squeeze(sqrt(sum((xpml-xpbase).^2,1)));
      szassert(err,[npts*npat 2]);
      errMn = mean(err(:));
      errMdn = median(err(:));
      errMax = max(err(:));
      
      fprintf('Projection err, ML lib vs normalized2projected.\n');
      fprintf('  %d projected image pts. Mean/Mdn/Max (px): %.3g/%.3g/%.3g\n',...
        numel(err),errMn,errMdn,errMax);
    end
    
    function diagnosticsUndistort(obj)
      % Compare ML undistortPoints() to our functions
      
      fprintf(1,'\nRunning undistort diagnostics.\n');

      cs = obj.calSess;
      sp = obj.stroParams;
      cp1 = sp.CameraParameters1;
      cp2 = sp.CameraParameters2;
      [bs,calpts] = CalRigMLStro.getCalSessionBoardSet(cs);
      
      %calpts = bs.BoardPoints; % ipt, x/y, ipat, ivw
      [npts,d,npat,nvw] = size(calpts);
      calpts = permute(calpts,[1 3 2 4]);
      calpts = reshape(calpts,[npts*npat d nvw]);
      
      calptsUD(:,:,1) = undistortPoints(calpts(:,:,1),cp1);
      calptsUD(:,:,2) = undistortPoints(calpts(:,:,2),cp2);
      tmp = arrayfun(@(x)obj.projected2normalized(calpts(x,:,1)',1),1:npts*npat,'uni',0);
      xn(:,:,1) = cat(2,tmp{:});
      tmp = arrayfun(@(x)obj.projected2normalized(calpts(x,:,2)',2),1:npts*npat,'uni',0);
      xn(:,:,2) = cat(2,tmp{:});
      szassert(xn,[2 npts*npat 2]);
      
      calptsUDours(:,:,1) = cp1.IntrinsicMatrix' * [xn(:,:,1); ones(1,npts*npat)];
      calptsUDours(:,:,2) = cp2.IntrinsicMatrix' * [xn(:,:,2); ones(1,npts*npat)];
      calptsUDours = permute(calptsUDours(1:2,:,:),[2 1 3]);
      
      err = squeeze(sqrt(sum((calptsUD-calptsUDours).^2,2)));
      errMn = mean(err(:));
      errMdn = median(err(:));
      errMax = max(err(:));
      fprintf('Undistort points. Err, ML lib vs projected2normalized.\n');
      fprintf('  %d undistorted image pts. Mean/Mdn/Max (px): %.3g/%.3g/%.3g\n',...
        numel(err),errMn,errMdn,errMax);
    end
    
    function diagnosticsEPlines(obj)
      % Check generation of EP lines
      %
      % 1. Generate an EP line from cam1->2 (and vice versa); Project back
      % onto Cam1 (Cam2) and check that the line collapses to a single pt
      % 2. Generate an EP line from cam1->2 (and v.v.) and compute distance
      % of closest approach to matched point in view2 (view1).
      
      fprintf(1,'\nRunning epipolar line diagnostics.\n');

      cs = obj.calSess;
      sp = cs.CameraParameters;
      cp1 = sp.CameraParameters1;
      cp2 = sp.CameraParameters2;
      [bs,calpts] = CalRigMLStro.getCalSessionBoardSet(cs);
      %calpts = bs.BoardPoints; % ipt, x/y, ipat, ivw
      [npts,d,npat,nvw] = size(calpts);
      calpts = permute(calpts,[1 3 2 4]);
      calpts = reshape(calpts,[npts*npat d nvw]);
      roi = [1 bs.ImageSize(2) 1 bs.ImageSize(1)];
      
      [~,xp1rp,xp2rp] = ...
        obj.stereoTriangulate(calpts(:,:,1)',calpts(:,:,2)');
      
      nzrange = cellfun(@numel,obj.eplineZrange);
      
      Xep1 = nan(3,nzrange(1),npts*npat); % 3d coords EP line from vw1
      Xep2 = nan(3,nzrange(2),npts*npat);
      ep12 = nan(nzrange(1),2,npts*npat); % ep line from vw1->vw2
      ep21 = nan(nzrange(2),2,npts*npat);
      ep12err = nan(npts*npat,1); % min L2 err from ep12 to matched pt in vw2
      ep21err = nan(npts*npat,1);
      xp1EPbackproj = nan(nzrange(1),2,npts*npat); % ep12 projected back onto vw1
      xp2EPbackproj = nan(nzrange(2),2,npts*npat);
      backProjErr = nan(npts*npat,2); % max L2 err of epprojback* onto orig pt. cols are vws
      for i=1:npts*npat
        if mod(i,50)==0
          disp(i);
        end
        
        [ep12(:,1,i),ep12(:,2,i),Xep1(:,:,i)] = obj.computeEpiPolarLine(1,xp1rp(:,i),2,roi);
        [ep21(:,1,i),ep21(:,2,i),Xep2(:,:,i)] = obj.computeEpiPolarLine(2,xp2rp(:,i),1,roi);
        xp1EPbackproj(:,:,i) = worldToImage(cp1,eye(3),[0 0 0],Xep1(:,:,i)','applyDistortion',true);
        xp2EPbackproj(:,:,i) = worldToImage(cp2,eye(3),[0 0 0],Xep2(:,:,i)','applyDistortion',true);
        
        tmp = sqrt(sum((ep12(:,:,i)-xp2rp(:,i)').^2,2));
        szassert(tmp,[nzrange(1) 1]);
        ep12err(i) = min(tmp);
        tmp = sqrt(sum((ep21(:,:,i)-xp1rp(:,i)').^2,2));
        szassert(tmp,[nzrange(2) 1]);
        ep21err(i) = min(tmp);
        
        tmp = sqrt(sum((xp1EPbackproj(:,:,i)-xp1rp(:,i)').^2,2));
        szassert(tmp,[nzrange(1) 1]);
        backProjErr(i,1) = max(tmp(:));
        tmp = sqrt(sum((xp2EPbackproj(:,:,i)-xp2rp(:,i)').^2,2));
        szassert(tmp,[nzrange(2) 1]);
        backProjErr(i,2) = max(tmp(:));
      end
      
      hFig = figure('Name','EP line diagnostics');
      axs = mycreatesubplots(2,2,[.15 0.1;.15 0.1]);
      for ivw=1:2
        ax = axs(1,ivw);
        axes(ax);
        if ivw==1
          mineperr = ep12err;
          tstr = sprintf('closestL2 epline shown in vw2');
        else
          mineperr = ep21err;
          tstr = sprintf('closestL2 epline shown in vw1');
        end
        histogram(mineperr);
        title(tstr,'fontweight','bold','fontsize',16); 
        mineperrMn = mean(mineperr);
        mineperrMdn = median(mineperr);
        mineperrMx = max(mineperr);
        fprintf('EP from vw%d, closest approach (px). Mean/Mdn/Max: %.3g/%.3g/%.3g\n',...
          ivw,mineperrMn,mineperrMdn,mineperrMx);        
        
        ax = axs(2,ivw);
        axes(ax);
        maxbperr = backProjErr(:,ivw);
        histogram(maxbperr);
        tstr = sprintf('Max backproj err, vw%d',ivw);
        title(tstr,'fontweight','bold','fontsize',16);
        maxbperrMn = mean(maxbperr);
        maxbperrMdn = median(maxbperr);
        maxbperrMx = max(maxbperr);
        fprintf('EP from vw%d, max backproj err (px). Mean/Mdn/Max: %.3g/%.3g/%.3g\n',...
          ivw,maxbperrMn,maxbperrMdn,maxbperrMx);        
      end

    end
    
  end
  
  methods (Static)
    function rperrPlot(rperrcam1,rperrcam2)
      % rperrcam1: [N x nphyspts] rp err
      
      szassert(rperrcam1,size(rperrcam2));
      [N,nphyspts] = size(rperrcam1);
      
      figure('Name','RP err');
      ax1 = axes;

      X = [rperrcam1 rperrcam2];
      Gcam = [repmat({'cam1'},nphyspts,1); repmat({'cam2'},nphyspts,1)];
      Gphyspt = [1:nphyspts 1:nphyspts]';
      boxplot(X,{Gphyspt Gcam},...
        ... %'colorgroup',Gcam,...
        'factorseparator',1,...
        'factorgap',[3 1]...
        );

      ylabel('RP err (px)','fontweight','bold','fontsize',14);
      title('RP err','fontweight','bold','fontsize',14);        
    end
  end
      
  methods % CalRig
    
    function xn = projected2normalized(obj,xp,cam,varargin)
      % ML-specific overload of project2normalized
      
      assert(size(xp,1)==2);
      xp = xp.';
      
      [iView,camName] = obj.camArgHelper(cam);
      cpFld = ['CameraParameters' num2str(iView)];
      sp = obj.stroParams;
      intprm = sp.(cpFld);
      if isprop(sp,'Intrinsics')
        % default MATLAB case
        % stereoParams.CameraParameters1 is a cameraParameters
        % <that>.Intrinsics is a cameraIntrinsics which is v similar
        intprm = intprm.Intrinsics;
      else
        % already intrinsics
      end
      xud = undistortPoints(xp,intprm);

      RDUMMY = eye(3);
      TDUMMY = [0;0;1]; % z=1; the API doesn't really make sense and is not well 
                   % documented, but this empirically works
      xn = pointsToWorld(intprm,RDUMMY,TDUMMY,xud); 
      xn = xn.';
    end
    
    function [xEPL,yEPL,Xc1,Xc1OOB] = ...
        computeEpiPolarLine(obj,iView1,xy1,iViewEpi,roiEpi,varargin)
      
      Xc1 = [];
      Xc1OOB = [];
      switch obj.eplineComputeMode
        case 'caltech'
          [xEPL,yEPL] = ...
            obj.computeEpiPolarLineCaltech(iView1,xy1,iViewEpi,roiEpi,varargin{:});
        case {'zray' 'mostaccurate'} % accept 'mostaccurate' for legacy
          [xEPL,yEPL,Xc1,Xc1OOB] = ...
            obj.computeEpiPolarLineZRay(iView1,xy1,iViewEpi,roiEpi,varargin{:});
        case 'fastest'
          warningNoTrace('DEVELOPMENT CODEPATH.');
          % This codepath will err if 3rd/4th args are requested
          [xEPL,yEPL] = obj.computeEpiPolarLineEPline(iView1,xy1,iViewEpi,roiEpi,varargin{:});
        otherwise
          error('Unrecognized value of ''eplineComputeMode'' property.');
      end
    end
      
    function [xEPL,yEPL] = ...
        computeEpiPolarLineCaltech(obj,iView1,xy1,iViewEpi,roiEpi,varargin)

      % "view"/"target" nomenclature here a little confusing
      % "view": where the EP line will be drawn; corresponds to iViewEpi
      % "target": origin of click/xy1; corresponds to iView1
      if iView1 == 1 % iViewEpi==2
        view_R = obj.RLR;
        view_T = obj.TLR;        
        ints_view = obj.int.cam2;
        ints_tgt = obj.int.cam1;
      else % iView1==2, iViewEpi==1
        view_R = obj.RRL;
        view_T = obj.TRL;        
        ints_view = obj.int.cam1;
        ints_tgt = obj.int.cam2;
      end
      view_fc = ints_view.fc;
      view_cc = ints_view.cc-1;
      view_kc = ints_view.kc;
      view_alpha_c = ints_view.alpha_c;
      target_fc = ints_tgt.fc;
      target_cc = ints_tgt.cc-1;
      target_kc = ints_tgt.kc;
      target_alpha_c = ints_tgt.alpha_c;

      xLp = [xy1(1), xy1(2)] - 1;
      xLp = xLp';
      epipole = compute_epipole2(xLp, view_R, view_T, ...
        view_fc, view_cc, view_kc, view_alpha_c, ...
        target_fc, target_cc, target_kc, target_alpha_c,...
        'roi',roiEpi);
      xEPL = epipole(1,:) + 1;
      yEPL = epipole(2,:) + 1;

      % we passed roiEpi to compute_epipole2 above, so we should already be
      % ballpark correct, but crop strictly so our axes don't get messed
      % up.
      CROP_ROI = true;
      if CROP_ROI
        xlo = roiEpi(1);
        xhi = roiEpi(2);
        ylo = roiEpi(3);
        yhi = roiEpi(4);
        tfrm = xEPL<xlo | xEPL>xhi | yEPL<ylo | yEPL>yhi;
        xEPL(tfrm) = [];
        yEPL(tfrm) = [];
      end
    end

    function [xEPL,yEPL,Xc1,Xc1OOB] = ...
        computeEpiPolarLineZRay(obj,iView1,xy1,iViewEpi,roiEpi,varargin)
      %
      % Xc1: [3 x nz] World coords (coord sys of cam/iView1) of EPline
      % Xc1OOB: [nz] indicator vec for Xc1 being out-of-view in iViewEpi
      
      [projectionmeth,z1Range] = myparse(varargin,...
        'projectionmeth','worldToImage',... % either 'worldToImage' or 'normalized2projected'. AL20181204: this should make negligible diff, see diagnostics()
        'z1Range',obj.eplineZrange{iView1} ...
        );
      
      % See CalRig
      %
      % z1Range: vector of world-z-coords to project onto iViewEpi
            
      xp = xy1(:);
      szassert(xp,[2 1]);            
      xn1 = obj.projected2normalized(xp,iView1);
      
      % create 3D segment by projecting normalized coords into 3D space
      % (coord sys of cam1)
      %Zc1 = 1e2:.25:2e2; % mm
      %Zc1 = 1:.25:5e2;
      Xc1 = [xn1(1)*z1Range; xn1(2)*z1Range; z1Range];

      switch projectionmeth
        case 'worldToImage'
          sp = obj.stroParams;
          cpEpiFld = ['CameraParameters' num2str(iViewEpi)];
          cpEpi = sp.(cpEpiFld); % camera parameters for viewEpi
          if iView1==1 && iViewEpi==2
            wp = Xc1'; % world coord sys is cam1 coord sys
            R = sp.RotationOfCamera2;
            T = sp.TranslationOfCamera2;
            imPoints = worldToImage(cpEpi,R,T,wp,'applyDistortion',true);
            imPointsUD = worldToImage(cpEpi,R,T,wp,'applyDistortion',false);            
          elseif iView1==2 && iViewEpi==1
            wp = obj.camxform(Xc1,[2 1]);
            wp = wp';
            R = eye(3);
            T = [0 0 0];
            imPoints = worldToImage(cpEpi,R,T,wp,'applyDistortion',true);
            imPointsUD = worldToImage(cpEpi,R,T,wp,'applyDistortion',false);
          else
            assert(false);
          end
          % AL 20220428: there was a reason we use imPointsUD here to crop;
          % maybe due to a rig with v high distortions. Probably a special
          % case though and better to just crop using imPoints (or in
          % caller, to share crop code with other methods)
          Xc1OOB = imPointsUD(:,1)<roiEpi(1) | imPointsUD(:,1)>roiEpi(2) |...
                   imPointsUD(:,2)<roiEpi(3) | imPointsUD(:,2)>roiEpi(4);
          imPoints(Xc1OOB,:) = nan;  
          xEPL = imPoints(:,1);
          yEPL = imPoints(:,2);
        case 'normalized2projected'
          warningNoTrace('DEVELOPMENT CODEPATH.');

          XcEpi = obj.camxform(Xc1,[iView1 iViewEpi]); % 3D seg, in frame of cam2
          xnEpi = [XcEpi(1,:)./XcEpi(3,:); XcEpi(2,:)./XcEpi(3,:)]; % normalize
          xpEpi = obj.normalized2projected(xnEpi,iViewEpi); % project
          
          Xc1OOB = xpEpi(1,:)<roiEpi(1) | xpEpi(1,:)>roiEpi(2) |...
                   xpEpi(2,:)<roiEpi(3) | xpEpi(3,:)>roiEpi(4);
          xpEpi(:,Xc1OOB) = nan;
          xEPL = xpEpi(1,:)';
          yEPL = xpEpi(2,:)';
        otherwise
          assert(false);
      end
    end
    
    function [xEPL,yEPL] = ...
        computeEpiPolarLineEPline(obj,iView1,xy1,iViewEpi,roiEpi,varargin)
      % Use worldToImage
      
      warningNoTrace('Development codepath.');
      
      xEPLnstep = 20;
      
      assert(numel(xy1)==2);
      sp = obj.stroParams;
      F = sp.FundamentalMatrix;
      
      if iView1==1 && iViewEpi==2
        lines = epipolarLine(F,xy1(:)');
      elseif iView1==2 && iViewEpi==1
        lines = epipolarLine(F',xy1(:)');
      else
        assert(false);
      end
      
      assert(numel(lines)==3);
      A = lines(1);
      B = lines(2);
      C = lines(3);
      xEPL = linspace(roiEpi(1),roiEpi(2),xEPLnstep)';
      yEPL = (-C-A*xEPL)/B;
      
      %tmp = obj.cropLines([yEPL xEPL],roiEpi);
      tmp = obj.getLineWithinAxes([yEPL xEPL],roiEpi);

      xEPL = tmp(:,2);
      yEPL = tmp(:,1);
    end
    
    function [X,uvrp,rpe] = triangulate(obj,xp)
      % CalRig impl. Forward to stereoTriangulate
      
      [d,n,nvw] = size(xp);
      assert(nvw==obj.nviews);
      
      uvrp = nan(d,n,nvw);
      rpe = nan(n,nvw);
      [X,uvrp(:,:,1),uvrp(:,:,2),rpe(:,1),rpe(:,2)] = ...
        obj.stereoTriangulate(xp(:,:,1),xp(:,:,2));
    end
    
    function [X1,xp1rp,xp2rp,rperr1,rperr2] = stereoTriangulate(obj,xp1,xp2)
      % Stereo triangulation using matlab/vision lib fcns
      % 
      % xp1: [2xn]. xy image coords, camera1
      % xp2: etc
      %
      % X1: [3xn]. 3D coords in frame of camera1
      % xp1rp: [2xn]. xy image coords, reprojected, cam1
      % xp2rp: etc
      % rperr1: [n]. L2 err orig vs reprojected, cam1.
      % rperr2: [n] etc.
      %
      % Note: this impl is not vectorized in any meaningful way (over cols
      % of xp1/xp2). undistortPoints is the expensive computation and it is
      % already going col by col. Calling this in a loop over single points
      % seems to hurt only by ~<10%.
            
      szassert(xp2,size(xp1));
      [d,n] = size(xp1);
      assert(d==2);
      
      sp = obj.stroParams;
      cp1 = sp.CameraParameters1;
      cp2 = sp.CameraParameters2;      
      
      % AL20181204: undistortPoints seems to scale like O(n^2) with input 
      % size. Break up input
      xp1ud = arrayfun(@(i)undistortPoints(xp1(:,i)',cp1),(1:n)','uni',0);
      xp1ud = cat(1,xp1ud{:});
      xp2ud = arrayfun(@(i)undistortPoints(xp2(:,i)',cp2),(1:n)','uni',0);
      xp2ud = cat(1,xp2ud{:});
      cm1 = cameraMatrix(cp1,eye(3),[0 0 0]);
      cm2 = cameraMatrix(cp2,sp.RotationOfCamera2,sp.TranslationOfCamera2);
      X1 = triangulate(xp1ud,xp2ud,cm1,cm2);
      % X1 = triangulate(...,sp); 
      % Don't use this sig beacuse in the case of .nonMLinit, MATLAB/Vision 
      % doesn't ducktype and requires a real stereoParameters type
      
      xp1rp = worldToImage(cp1,eye(3),[0;0;0],X1,'applyDistortion',true);
      xp2rp = worldToImage(cp2,...
        sp.RotationOfCamera2,sp.TranslationOfCamera2,X1,'applyDistortion',true);
      
      % shape conventions
      X1 = X1';
      xp1rp = xp1rp';
      xp2rp = xp2rp';
      rperr1 = sqrt(sum((xp1rp-xp1).^2,1));
      rperr2 = sqrt(sum((xp2rp-xp2).^2,1));      
    end    
    
    function [xRCT,yRCT] = reconstruct(obj,iView1,xy1,iView2,xy2,iViewRct)
      % iView1: view index for anchor point
      % xy1: [2]. [x y] vector, cropped coords in iView1
      % iView2: view index for 2nd point
      % xy2: [2]. etc
      % iViewRct: view index for target view (where reconstructed point will be drawn)
      %
      % xRCT: [3] Reconstructed point spread, iViewRct, cropped coords
      % yRCT: [3] etc.
      % A "point spread" is 3 points specifying a line segment for a 
      % reconstructed point. The midpoint of the line segment (2nd point in
      % point spread) is the most likely reconstructed location. The two
      % endpoints represent extremes that lie precisely on one EPL (but not
      % necessarily the other and vice versa).
    
      assert(false,'Unimplemented.');
    end
       
  end
  
  methods (Static)
    function [bs,bps] = getCalSessionBoardSet(cs)
      if isprop(cs,'BoardSet')
        bs = cs.BoardSet;
        bps = bs.BoardPoints;
      elseif isprop(cs,'PatternSet')
        bs = cs.PatternSet;
        bps = bs.PatternPoints;
      else
        error('Cannot find ''BoardSet'' property in CalibrationSession.');
      end
    end
    function [fc,cc,kc,alpha_c] = camParams2Intrinsics(camParams)
      % convert ML-style intrinsics to Bouget-style
      %
      % Note: cc is still 1-based not 0-based!
      % Note: alpha_c has a slightly different defn compared to .Skew!
      
      fc = camParams.FocalLength(:);
      assert(numel(fc)==2);
      
      cc = camParams.PrincipalPoint(:);
      assert(numel(cc)==2);
            
      kc = nan(5,1);
      raddistort = camParams.RadialDistortion;
      if numel(raddistort)==2
        raddistort(end+1) = 0;
      end
      kc([1 2 5]) = raddistort;
      
      tandistort = camParams.TangentialDistortion;
      kc([3 4]) = tandistort;
      
      alpha_c = camParams.Skew/fc(1);
      assert(isscalar(alpha_c));
    end
    function cs = rigYaml2CalSess(s)
      % s: struct, rig yaml
      cs = struct();
      cs.cameraSet = CameraSet(s);
      cs.CameraParameters = cs.cameraSet.getMatlabStereoParameters();
    end
  end

end
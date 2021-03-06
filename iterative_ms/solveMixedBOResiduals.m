function [corrFunc, its] = solveMixedBOResiduals(resSol, wellSol, G, rock, ...
                                            S, CG, fluid, p0, dt, LS, ...
                                            overlap, varargin)

%--------------------------------------------------------------------------
%

opt = struct('LinSolve', @mldivide, 'tol', 1e-3, 'Verbose', true, ...
             'maxIt', 100);
opt = merge_options(opt, varargin{:});

fprintf('   Computing correction functions ....\n');

% Set up the structure representing the support for overlapping correction
% functions
subCellsOverlap = CG.cells.subCells;
if overlap > 0,
   % Generate neighbour matrix
   intF = prod(double(G.faces.neighbors), 2) > 0;
   neighborMatrix = sparse([(1 : G.cells.num) .';
                            double(G.faces.neighbors(intF, 1));
                            double(G.faces.neighbors(intF, 2))], ...
                           [(1 : G.cells.num) .';
                            double(G.faces.neighbors(intF, 2));
                            double(G.faces.neighbors(intF, 1))], ...
                           1, G.cells.num, G.cells.num);
   for j = 1 : overlap,
      subCellsOverlap = logical(neighborMatrix * subCellsOverlap);
   end
end

%------ Unpack solutions and preserve initial values ----------------------
neumGP    = [LS.fluxFacesR; LS.fluxFacesW];
diriGP    = [LS.pFacesR; LS.pFacesW];
faceFluxI = [resSol.faceFlux; vertcat( wellSol.flux )];
pI        = resSol.cellPressure;
lam       = [resSol.facePressure; vertcat( wellSol.pressure )];
lamNI     = lam( [LS.fluxFacesR; LS.fluxFacesW] );

resSol0  = resSol;
wellSol0 = wellSol;

its = zeros(1,CG.cells.num);
indDPrev = false( size(LS.D,2), 1 );
for k = 1:CG.cells.num
   resSol  = resSol0;
   wellSol = wellSol0;
   faceFlux = faceFluxI;
   p  = pI;
   lamN = lamNI;
   
   indC    = CG.cells.subCells(:, k);
   if overlap>0
      indCO = subCellsOverlap(:, k);
   else
      indCO = [];
   end
   if opt.Verbose
      fprintf(['Solving correction function: ' num2str(k) '\n']);
   end
   resetF = false;
   if isempty( indCO), indCO = indC; resetF=true; end
   
   [indB, indBO, indD, indDO] = getInds( indC, indCO, LS.C, LS.D );
   
   %hack
   indB = logical( LS.D *(indD.*(~indDPrev)) );
   indB = indB.*indBO;
   indDPrev = indD + indDPrev;
   
   % find Neumann faces for local Problem
   % This can be simplified !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
   neumLP = logical( logical( sum(LS.Do' *sparse(1:numel(indBO), ...
      1:numel(indBO),indBO) * LS.D(:, indDO), 2) ) .* (~diriGP) );

   [inc,res] = deal(inf);
   
   
   while (max(inc,res) > opt.tol) && its(k) < opt.maxIt

      LS = setupMixedBO(resSol, wellSol, G, rock, S, fluid, p0, dt, LS);

      % RHS
      fc = LS.f .* indB; fc = fc(indBO);
      gc = LS.g .* indC; gc = gc(indCO);
         
      DNc = LS.D(indBO, neumLP);
      if resetF, fc(logical(sum(DNc,2))) = 0; end
       
      % residuals
      resNorms.f = norm(fc)/(max(p)-min(p));
      resNorms.g = norm(gc)/norm(faceFlux);
       
      if max(resNorms.f, resNorms.g) > opt.tol
          
         % create sub-matrices
         Bc  = LS.B(indBO, indBO);
         Cc  = LS.C(indBO, indCO);
         Pc  = LS.P(indCO, indCO);
         Doc = LS.Do(indBO, indDO);
          
         % RHS, continued
         h = zeros(size(LS.D,2), 1);
         h(neumGP) = LS.hN;
         h = h .* indD; hNc = h(neumLP);
         
         [flux_sub, p_sub, lamN_sub] = ...
            solveMixedLinSys(Bc, Cc, DNc, Pc, fc, gc, hNc, Doc);
         
         flux_inc        = zeros( size(faceFlux) );
         flux_inc(indDO) = flux_sub;
         p_inc           = zeros( size(p) );
         p_inc(indCO)    = p_sub;
         lam             = zeros( numel(neumGP), 1 );
         lam(neumLP)     = lamN_sub;
         lamN_inc        = lam(neumGP);
         
         faceFlux = faceFlux + flux_inc;
         p    = p + p_inc;
         lamN = lamN + lamN_inc;
         
         incNorms.flux     = norm(flux_inc)/norm(faceFlux);
         incNorms.pressure = norm(p_inc)/(max(p)-min(p));
         
  %       clf; plotCellData(G,LS.C'*abs(LS.f),'edgecolor','k'); colorbar; view(2)
         [resSol, wellSol] = ...
            packSol(G, LS.wells, resSol, wellSol, faceFlux, p, lamN, LS.bc);
 %        LS = setupMixedBO(resSol, wellSol, G, rock, S, fluid, p0, dt, LS);
 %        clf; plotCellData(G,LS.C'*abs(LS.f),'edgecolor','k'); colorbar; view(2)
         
         its(k) = its(k) + 1;
         LS.solved = true;
      else
         incNorms.flux     = 0;
         incNorms.pressure = 0;
         LS.solved = false;
      end
      inc = max(incNorms.flux, incNorms.pressure);
      res = max(resNorms.f, resNorms.g);
      if opt.Verbose
         %fprintf('   %0*d: Max RelIncNorm = %10.4e\n', 3, it, inc);
         fprintf('   %0*d: Max RelResNorm = %10.4e\n', 3, its(k), res);
      end
   end
   corrFunc(k).resSol  = resDiff(resSol, resSol0);
   corrFunc(k).wellSol = wellDiff(wellSol, wellSol0);
end

%--------------------------------------------------------------------------

function [indB, indBO, indD, indDO] = getInds( indC, indCO, C, D )
indB  = logical( C * indC   );
indBO = logical( C * indCO  );
indD  = logical( D' * indB  );
indDO = logical( D' * indBO );

%--------------------------------------------------------------------------

function [resSol, wellSol] = packSol(G, W, resSol, wellSol, flux, ...
                                     p, lamN, bc)
fluxFacesR = getBCType(G, W, bc);
facePressure = zeros(G.faces.num, 1);
if ~isempty(bc)
    pf = strcmpi('pressure', bc.type');
    presFaces = double(bc.face(pf));
    facePressure(presFaces) = bc.value(pf);
end
facePressure(fluxFacesR) = lamN(1:nnz(fluxFacesR));

resSol.facePressure = facePressure;
resSol.cellPressure = p;
resSol.faceFlux     = flux(1:G.faces.num);
resSol.cellFlux     = faceFlux2cellFlux(G, flux);

%wells
r_inx = G.faces.num;
p_inx = numel(fluxFacesR);
for k = 1:numel(W)
    if strcmpi(W(k).type, 'pressure')
       wellSol(k).pressure = W(k).val;
    else
        wellSol(k).pressure = lamN(p_inx+1);
        p_inx = p_inx+1;
    end
    nwc = numel(W(k).cells);
    wellSol(k).flux = - flux(r_inx + (1:nwc));
    r_inx = r_inx + nwc;
end

%--------------------------------------------------------------------------

function resSol = resDiff( resSol, rs)
fn = fieldnames(resSol);
for k = 1:numel(fn)
    resSol.(fn{k}) = resSol.(fn{k}) - rs.(fn{k}); 
end

%--------------------------------------------------------------------------

function wellSol = wellDiff( wellSol, ws)
for wNr = 1 : numel(wellSol)
    fn = fieldnames(wellSol(k));
    for k = 1:numel(fn)
        wellSol(wNr).(fn{k}) = wellSol(wNr).(fn{k}) - ws(wNr).(fn{k});
    end
end
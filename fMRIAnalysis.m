%This script demonstrates the model-based MVPA procedure.
%
%
%Author: Jiefeng Jiang
%Ref: https://elifesciences.org/articles/39497
%
%Input arguments:
%featureName: a .mat file contains a (trialNum x voxelNum) matrix named,
%"features", which encodes activity level at each trial and each voxel
%
%regressor: a matrix encoding trial-wise model variable estimates (e.g., P_int), can
%have multiple columuns, with each column representing one model variale
%
%neighborName: a file contains searchlight information.
%
%saveName: name of the file containing all results
%
%mask: a array encoding whether the trial is excluded from analysis (if 1),
%or not (if 0)
%
%nuisanceM: nuisance regressors, not used in this paper
%
%For the purpose of this paper:
%foldsTraining = [1 2 3 4 5 6; 1 2 3 7 8 9; 4 5 6 7 8 9];
%foldsTest = [7 8 9; 4 5 6; 1 2 3];
%
%maskName, a binary file showing which searchlights are excluded from
%analysis. Not used in this paper.

function accuracy = fMRIAnalysis(featureName, regressor, neighborName, saveName, mask, nuisanceM, foldsTraining, foldsTest, maskName)

%the dimension of the images
dim = [53 63 46];

nFold = size(foldsTraining, 1);

%Load mask if not whole-brain analysis (Not used in this paper)
if ~isempty(maskName)
    fid = fopen(maskName,'r');
    voxelMask = fread(fid, inf, 'float32');
    fclose(fid);
else
    voxelMask = ones(1, dim(1) * dim(2) * dim(3));
end

voxelId = [];
fidNeighbor = fopen(neighborName, 'r');
%get GM indices
len = fread(fidNeighbor, 1, 'int32');
idxGM = fread(fidNeighbor, len, 'int32');

regressorNum = size(regressor, 2);

%read features from files
data = load(featureName);
runLength = 50;
nRun = size(data.features, 1) / runLength;
features = cell(nRun, 1);
mask = reshape(mask, [runLength, nRun]);

size(data.features, 2)
for j = 1 : nRun
    features{j} = data.features((j - 1) * runLength + 1 : j * runLength, :);
    features{j} = features{j}(mask(:, j), :);
    
    %normalize features within each run
    features{j} = (features{j} - repmat(mean(features{j}), [size(features{j}, 1), 1]));
    for k = 1 : size(features{j}, 2)
        if std(features{j}(:, k)) > 0
            features{j}(:, k) = features{j}(:, k) / std(features{j}(:, k));
        end
    end
end
clear('data');

%read regressors and filter out masked trials
x = cell(nRun, 1);
nuisance = cell(nRun, 1);
pNuisance = cell(nRun, 1);

for i = 1 : nRun
    x{i} = regressor((i - 1) * runLength + 1 : i * runLength, :);
    x{i} = x{i}(mask(:, i), :);
    
    if ~isempty(nuisanceM)
        nuisance{i} = nuisanceM((i - 1) * runLength + 1 : i * runLength, :);
        nuisance{i} = nuisance{i}(mask(:, i), :);
        pNuisance{i} = pinv(nuisance{i});
    end
end
clear('regressors');

%remove nuisance effects (Not used in this paper)
if ~isempty(nuisanceM)
    for i = 1 : nRun
        x{i} = x{i} - nuisance{i} * pNuisance{i} * x{i};
        for j = 1 : size(features{i}, 2)
            x1 = features{i}(:, j);
            x1 = x1 - nuisance{i} * pNuisance{i} * x1;
            features{i}(:, j) = x1;
        end
    end
end

%spot light search
nTrainingRun = size(foldsTraining, 2);
nTestRun = size(foldsTest, 2);
tF = cell(1, 9);
count = 0;
while true
    [len, c] = fread(fidNeighbor, 1, 'int32');
    if c < 1
        break;
    end
    
    centerId = fread(fidNeighbor, 1, 'int32');
    idx1 = fread(fidNeighbor, len, 'int32');
    
    if voxelMask(idxGM(centerId)) < 0.5
        continue;
    end
    
    cv = zeros(1, regressorNum);
    
    count = count + 1;
    voxelId(count) = idxGM(centerId);
    accuracy(1:regressorNum, count) = 0;
        
    for i = 1 : nRun
        tF{i} = features{i}(:, idx1);
        idx2 = sum(abs(tF{i})) > 1e-3;
        tF{i} = tF{i}(:, idx2);
    end
    
    if (size(tF{1}, 2) < 1)
        continue;
    end
    
    %cross validation within each searchlight
    for i = 1 : nFold
        trainingX = [];
        testX = [];
        trainingY = [];
        testY = [];
        
        for j = 1 : nTrainingRun
            trainingX = [trainingX; tF{foldsTraining(i, j)}];
            trainingY = [trainingY; x{foldsTraining(i, j)}];
        end
        
        trainingX = [trainingX ones(size(trainingX, 1), 1)];

        pInvTrainingX = pinv(trainingX);
        betas =  pInvTrainingX * trainingY;
        
        %Xue et al (2010)'s ridge-regression
        trainingErr = trainingY - trainingX * betas;
        errSquare = sum(trainingErr .* trainingErr) / (size(trainingX, 1) - 1);
        kFactor = size(trainingX, 2) * errSquare ./ (sum(betas .* betas));
        
        XtX = trainingX' * trainingX;
        XtY = trainingX' * trainingY;
        IMat = eye(size(trainingX, 2));
        
        bestR = 0;
        maxIdx = 0;
        for j = 1 : length(kFactor)
            betas(:, j) = pinv(XtX + kFactor(j) * IMat) * XtY(:, j);
        end
        
        for j = 1 : nTestRun
            testX = [testX; tF{foldsTest(i, j)}];
            testY = [testY; x{foldsTest(i, j)}];
        end
        
        testX = [testX ones(size(testX, 1), 1)];
        simY = testX * betas;
 
        for j = 1 : regressorNum
            r1 = corrcoef(simY(:, j), testY(:, j));
            z1 = 0.5 * log((r1(1, 2) + 1) / (1 - r1(1, 2))) * sqrt(length(simY) - 3);
            cv(j) = cv(j) + z1;
        end
    end
    
    accuracy(1:regressorNum, count) = cv / nFold;
    
end

fclose(fidNeighbor);

[~, voxelIdx] = sort(voxelId);
accuracy = accuracy(:, voxelIdx);

save(saveName, 'accuracy', 'voxelIdx');  
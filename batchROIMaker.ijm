function closeAll() {
    while (nImages > 0) {
        selectImage(nImages);
        close();
    }
}

macro "Batch_ProcessND2_RemoveOutlierROIs_FilledColors" {
    // -----------------------------
    // 1. Select Folder Containing ND2 Files
    // -----------------------------
    dir = getDirectory("Choose a Directory Containing ND2 Files");
    if (dir == "") exit("No directory selected.");

    // -----------------------------
    // 2. Get List of ND2 Files
    // -----------------------------
    list = getFileList(dir);
    nd2Files = newArray();
    for (i = 0; i < list.length; i++) {
        if (endsWith(list[i], ".nd2") || endsWith(list[i], ".ND2")) {
            nd2Files = Array.concat(nd2Files, list[i]);
        }
    }
    
    if (nd2Files.length == 0) {
        exit("No ND2 files found in the selected directory.");
    }

    // -----------------------------
    // 3. Initialize Results Table
    // -----------------------------
    run("Clear Results");
    totalResults = 0;  // Track position in results table

    // -----------------------------
    // 4. Process Each ND2 File
    // -----------------------------
    setBatchMode(false); // Keep GUI visible for interactive parts
    for (f = 0; f < nd2Files.length; f++) {
        fileName = nd2Files[f];
        filePath = dir + fileName;
        print("\nProcessing: " + fileName);

        // Open current ND2 file
        run("Bio-Formats Importer", "open=[" + filePath + "] autoscale color_mode=Default split_channels view=Hyperstack stack_order=XYCZT");

        //-----------------------------------------------------
        // 5) Identify open ND2 channels & close C=0
        //-----------------------------------------------------
        listTitles = getList("image.titles");
        c0 = ""; c1 = ""; c2 = "";

        for (i = 0; i < listTitles.length; i++) {
            title = listTitles[i];
            if (indexOf(title, "C=0") != -1)       { c0 = title; }
            else if (indexOf(title, "C=1") != -1)  { c1 = title; }
            else if (indexOf(title, "C=2") != -1)  { c2 = title; }
        }
        if (c0 != "") {
            selectWindow(c0);
            close();
        }
        if (c1=="") {
            print("Error: Channel 1 (C=1) not found in " + fileName);
            closeAll();
            continue;
        }
        if (c2=="") {
            print("Error: Channel 2 (C=2) not found in " + fileName);
            closeAll();
            continue;
        }

        //-----------------------------------------------------
        // 6) Max Projection on channel 1 -> "Max_C1"
        //-----------------------------------------------------
        selectWindow(c1);
        run("Z Project...", "projection=[Max Intensity]");
        rename("Max_C1");
        selectWindow("Max_C1");

        //-----------------------------------------------------
        // 7) Interactive Preview for sigma + threshold
        //-----------------------------------------------------
        userIsSatisfied = false;
        defaultSigma = 2;
        defaultLower = 100;
        userUpper = 65535;

        while (!userIsSatisfied) {
            Dialog.create("Preview Settings - Image " + (f+1) + "/" + nd2Files.length);
            Dialog.addMessage("Current file: " + fileName);
            Dialog.addNumber("Gaussian Blur Sigma:", defaultSigma);
            Dialog.addNumber("Threshold Lower Bound:", defaultLower);
            Dialog.show();
            userSigma = Dialog.getNumber();
            userLower = Dialog.getNumber();

            selectWindow("Max_C1");
            run("Duplicate...", "title=Preview_C1");
            selectWindow("Preview_C1");

            run("Gaussian Blur...", "sigma="+userSigma);
            setThreshold(userLower, userUpper);
            run("Convert to Mask");
            run("Fill Holes");
            run("Make Binary");
            run("Watershed");

            Dialog.create("Preview OK? - Image " + (f+1) + "/" + nd2Files.length);
            Dialog.addMessage("Close 'Preview_C1' to inspect.\nAre you satisfied?");
            Dialog.addChoice("Answer:", newArray("Yes","No"), "Yes");
            Dialog.show();
            choice = Dialog.getChoice();

            if (choice=="Yes") {
                userIsSatisfied = true;
            }
            selectWindow("Preview_C1");
            close();
        }

        // Ask for outlier parameters
        Dialog.create("Outlier Settings - Image " + (f+1) + "/" + nd2Files.length);
        Dialog.addMessage("Current file: " + fileName);
        Dialog.addCheckbox("Filter by Area", true);
        Dialog.addCheckbox("Filter by Circularity", false);
        Dialog.addNumber("Factor (±% from mean):", 50);
        Dialog.show();
        filterByArea = Dialog.getCheckbox();
        filterByCirc = Dialog.getCheckbox();
        factor = Dialog.getNumber() / 100;

        //-----------------------------------------------------
        // 8) Apply final steps to "Max_C1"
        //-----------------------------------------------------
        selectWindow("Max_C1");
        run("Gaussian Blur...", "sigma="+userSigma);
        setThreshold(userLower, userUpper);
        run("Convert to Mask");
        run("Fill Holes");
        run("Make Binary");
        run("Watershed");

        //-----------------------------------------------------
        // 9) Analyze Particles -> store ROIs
        //-----------------------------------------------------
        if (isOpen("ROI Manager")) {
            roiManager("Reset");
        } else {
            run("ROI Manager...");
        }

        run("Set Measurements...", "area mean shape feret perimeter display add redirect=None decimal=3");
        run("Analyze Particles...", "size=50-Infinity circularity=0.20-1.00 clear add include display");

        //-----------------------------------------------------
        // 10) Remove outliers by area OR circularity
        //-----------------------------------------------------
        nRois = roiManager("count");
        if (nRois == 0) {
            print("No ROIs found in " + fileName);
            closeAll();
            continue;
        }

        sumArea = 0;
        sumCirc = 0;
        for (r = 0; r < nRois; r++) {
            sumArea += getResult("Area", r);
            sumCirc += getResult("Circ.", r);
        }
        meanArea = sumArea / nRois;
        meanCirc = sumCirc / nRois;

        removeArray = newArray(nRois);
        for (r = 0; r < nRois; r++) {
            thisArea = getResult("Area", r);
            thisCirc = getResult("Circ.", r);

            keepFlag = true;
            if (filterByArea) {
                minArea = meanArea * (1.0 - factor);
                maxArea = meanArea * (1.0 + factor);
                if (thisArea < minArea || thisArea > maxArea) {
                    keepFlag = false;
                }
            }
            if (filterByCirc) {
                minCirc = meanCirc * (1.0 - factor);
                maxCirc = meanCirc * (1.0 + factor);
                if (thisCirc < minCirc || thisCirc > maxCirc) {
                    keepFlag = false;
                }
            }
            removeArray[r] = !keepFlag;
        }

        //-----------------------------------------------------
        // 11) Show preview of outliers
        //-----------------------------------------------------
        selectWindow("Max_C1");
        run("Duplicate...", "title=Outlier_Preview");
        selectWindow("Outlier_Preview");
        run("RGB Color");

        roiManager("Deselect");
        roiManager("Show All without labels");

        for (r = 0; r < nRois; r++) {
            roiManager("Select", r);
            if (removeArray[r]) {
                setColor("red");
                run("Fill");
            } else {
                setColor("green");
                run("Fill");
            }
        }

        Dialog.create("Remove Outliers? - Image " + (f+1) + "/" + nd2Files.length);
        Dialog.addMessage("Check 'Outlier_Preview'.\nRED = removed, GREEN = kept.\nContinue with these selections?");
        Dialog.addChoice("Answer:", newArray("Yes","No"), "Yes");
        Dialog.show();
        choice2 = Dialog.getChoice();
        if (choice2=="No") {
            print("User canceled processing of " + fileName);
            closeAll();
            continue;
        }
        selectWindow("Outlier_Preview");
        close();

        //-----------------------------------------------------
        // 12) Remove outlier ROIs from ROI Manager
        //-----------------------------------------------------
        for (r = nRois-1; r >= 0; r--) {
            if (removeArray[r]) {
                roiManager("Select", r);
                roiManager("Delete");
            }
        }


// 13) Average Projection on channel 2 and measure
        //-----------------------------------------------------
        selectWindow(c2);
        run("Z Project...", "projection=[Average Intensity]");
        rename("Avg_C2");
        selectWindow("Avg_C2");

        // Clear previous results
        run("Clear Results");
        
        // Measure only kept ROIs on C2
        run("Set Measurements...", "mean min max standard area redirect=None decimal=3");
        nRois = roiManager("count");
        
        if (nRois > 0) {
            roiManager("Show All");
            roiManager("Measure");
            
            // Create temporary arrays to store measurements
            area = newArray(nResults);
            mean = newArray(nResults);
            stdDev = newArray(nResults);
            min = newArray(nResults);
            max = newArray(nResults);
            
            // Store measurements in arrays
            for (r = 0; r < nResults; r++) {
                area[r] = getResult("Area", r);
                mean[r] = getResult("Mean", r);
                stdDev[r] = getResult("StdDev", r);
                min[r] = getResult("Min", r);
                max[r] = getResult("Max", r);
            }
            
            // Clear results and rebuild with image name
            run("Clear Results");
            
            // Rebuild results table with all data including image name
            for (r = 0; r < nRois; r++) {
                setResult("Area", r, area[r]);
                setResult("Mean", r, mean[r]);
                setResult("StdDev", r, stdDev[r]);
                setResult("Min", r, min[r]);
                setResult("Max", r, max[r]);
                setResult("Image", r, fileName);
            }
            updateResults();
            
            // Append to CSV
            if (f == 0) {
                // Create headers for first image
                headers = "Area,Mean,StdDev,Min,Max,Image\n";
                File.saveString(headers, dir + "AllResults.csv");
            }
            
            // Append current results
            for (r = 0; r < nResults; r++) {
                line = d2s(getResult("Area", r), 6) + "," +
                       d2s(getResult("Mean", r), 6) + "," +
                       d2s(getResult("StdDev", r), 6) + "," +
                       d2s(getResult("Min", r), 0) + "," +
                       d2s(getResult("Max", r), 0) + "," +
                       fileName + "\n";
                File.append(line, dir + "AllResults.csv");
            }
        }

        //-----------------------------------------------------
        // 14) Cleanup for next file
        //-----------------------------------------------------
        closeAll();
        print("Completed processing: " + fileName + " and added to AllResults.csv");

    //-----------------------------------------------------
    // 15) Final completion message
    //-----------------------------------------------------
    print("\nBatch processing complete! Results saved to: " + dir + "AllResults.csv");
}

library(data.table)
library(glmnet)
library(ggplot2)
library(gridExtra)
library(pheatmap)

# script only looks at the first column of the metadata file (for sample names) and the second column (for the assigned class/group/category/celltype to each sample)
# metadata file must have column names and they could be anything, after reading in metadata file, the two columns are named as "sample_name" and "group"
# An example metadata file:
#Run	type
#SRR8788980	carcinoma
#SRR8788981	melanoma
#SRR8788982	lymphoma
#SRR8788983	carcinoma
#SRR8657060	carcinoma

args <- commandArgs(trailingOnly = TRUE)
directory = args[1] # example: "/oak/stanford/groups/horence/Roozbeh/NOMAD_10x/runs/CCLE_all/"
metadata_file = args[2] # example: "/oak/stanford/groups/horence/Roozbeh/NOMAD_10x/utility_files/CCLE_metadata_modified.tsv"
run_name = args[3] # the output files and plots will be generated in ${directory}/${run_name}_supervised_metadata
datatype = args[4] # could be either "10x" or "non10x" 
if (length(args) == 5){
  selected_anchors = fread(args[5])
} else{
  anchor_sample_fraction_cutoff = as.numeric(args[5]) # the cutoff for the minimum fraction of samples for each anchor, suggested 0.4
  num_anchors_for_supervised_test = as.numeric(args[6]) # maximum number of anchors to be tested example, suggested 20000
}


############## reading in metadata and sample_conversion files #########################
metadata = fread(metadata_file)
sample_name_id_conversion = fread(paste(directory,"sample_name_to_id.mapping.txt",sep=""),header = FALSE)
###############################################################

################################################################
##### select the anchors for the supervised GLM when no specific list of anchors is provided ################
if (length(args) == 6){
  anchors = fread(paste(directory,"result.after_correction.scores.tsv",sep=""),select = c("anchor", "effect_size_bin", "number_nonzero_samples", "most_freq_target_1", "cnt_most_freq_target_1", "most_freq_target_2", "cnt_most_freq_target_2","avg_hamming_distance_max_target"))
  max_sample_num = max(anchors$number_nonzero_samples,na.rm = TRUE)
  anchors = anchors[number_nonzero_samples > (max_sample_num * anchor_sample_fraction_cutoff) & avg_hamming_distance_max_target > 1] ## keep only anchors that are in at least the given fraction of samples 
  setorder(anchors,-effect_size_bin)
  selected_anchors = anchors[1:min(num_anchors_for_supervised_test,nrow(anchors)),]
}
################################################################
################################################################

system(paste("mkdir ", directory,"/",run_name,"_supervised_metadata",sep="")) # this is the directory for the supervised analysis files
##################################################################################
####### satc_dump for getting counts for the selected anchors ####################
write.table(selected_anchors$anchor,paste(directory, "/",run_name,"_supervised_metadata/", "selected_anchors_GLMnet.txt",sep=""),sep="\t",row.names=FALSE,quote=FALSE,col.names = FALSE)
num_files <- length(list.files(paste0(directory, "/result_satc")))
for (counter in 0:(num_files-1)){
  system(paste("/sps/sallegen/mchour/tools/SPLASH/satc_dump --anchor_list ", paste(directory, "/",run_name,"_supervised_metadata/", "selected_anchors_GLMnet.txt ", sep = ""), directory, "result_satc/bin", counter, ".satc ", directory, "/",run_name,"_supervised_metadata/", "satcOut",counter,".tsv ", sep = ""))
}
# now below I read in satcout files generated by satc_dump
satcOut_files = list.files(path = paste(directory,"/",run_name,"_supervised_metadata/",sep=""), pattern = "satcOut")
counts = data.table()
for (counter in 1:length(satcOut_files)) {
  counts = rbind(counts, fread(paste(directory,"/",run_name,"_supervised_metadata/",satcOut_files[counter], sep = ""))) 
  print(counter)
}
if (datatype == "non10x"){
  setnames(counts,c("V1","V2","V3","V4"),c("sample_id","anchor","target","count"))
} else if (datatype == "10x"){
  setnames(counts,c("V1","V2","V3","V4","V5"),c("sample_id","cell_barcode","anchor","target","count"))
}
###################################################################################
###################################################################################

################# merging counts with metadata #######################
######################################################################
if (datatype=="non10x"){
  metadata = metadata[,c(1,2)]
  names(metadata) = c("sample_name", "group")
  metadata = merge(metadata, sample_name_id_conversion, all.x = TRUE, all.y = FALSE, by.x="sample_name", by.y="V1")
  metadata = metadata[!is.na(V2)]
  counts = merge(counts, metadata, all.x = TRUE, all.y = FALSE, by.x = "sample_id", by.y = "V2")
} else{
  metadata = metadata[,c(1,2,3)]
  names(metadata) = c("sample_name", "cell_barcode", "group")
  metadata = merge(metadata, sample_name_id_conversion, all.x = TRUE, all.y = FALSE, by.x="sample_name", by.y="V1")
  metadata = metadata[!is.na(V2)]
  metadata$sample_id = paste(metadata$cell_barcode,metadata$V2,sep="_")
  metadata$sample_name = paste(metadata$cell_barcode,metadata$sample_name,sep="_")
  metadata =  metadata[,list(sample_name,sample_id,group)]
  counts$sample_id = paste(counts$cell_barcode,counts$sample_id,sep="_")
  counts[,cell_barcode:=NULL]
  counts = merge(counts, metadata, all.x = TRUE, all.y = FALSE, by.x = "sample_id", by.y = "sample_id")
  counts =  counts[!is.na(sample_name)]
}
######################################################################
######################################################################

system(paste("mkdir ", directory,"/",run_name,"_supervised_metadata/plots",sep=""))
GLM_output_dt = data.table() # the data table that will keep glm information for the selected anchors
#############################################################
####### perform GLM for each selected anchor ################
for (counter in 1:nrow(selected_anchors)){
  tryCatch({
    anchor_interest = selected_anchors$anchor[counter]
    counts_anchor = counts[anchor==anchor_interest] # target counts for the selected anchor 
    counts_anchor[,target_count := sum(count),by=target] # compute total counts for each target
    top_targets = counts_anchor[!duplicated(target)][order(-target_count)]$target[1:4] # find the top two targets
    counts_anchor[!target%in%top_targets,target:="other"] # assigning all targets after target 4 to other targets
    counts_anchor = counts_anchor[target %in% top_targets][order(-target_count)] # add all "other" targets to the end of the counts_anchor
    counts_anchor[,target_count := sum(count),by=target] # again recompute target count as now I have collapsed targets after target 4 to "other" targets
    counts_anchor = counts_anchor[!duplicated(paste(anchor,target,sample_name))] # remove duplicate entries where there are now multiple other targets per anchor and sample
    
    counts_anchor[,anchor_count_per_sample:=sum(count),by=list(anchor,sample_name)]
    counts_anchor[,fraction:=count/anchor_count_per_sample,by=1:nrow(counts_anchor)] # compute target fraction per sample
    counts_anchor = counts_anchor[anchor_count_per_sample>5]
    counts_anchor_reshape = reshape(counts_anchor[,list(sample_name,target,fraction,count)], idvar="sample_name", timevar="target", direction="wide")
    
    if (ncol(counts_anchor_reshape) == 11){
      names(counts_anchor_reshape) = c("sample_name","target1_frac","target1_count","target2_frac","target2_count","target3_frac","target3_count","target4_frac","target4_count","other_frac","other_count")
    } else if (ncol(counts_anchor_reshape) == 9){
      names(counts_anchor_reshape) = c("sample_name","target1_frac","target1_count","target2_frac","target2_count","target3_frac","target3_count","target4_frac","target4_count")
    }else if (ncol(counts_anchor_reshape) == 7){
      names(counts_anchor_reshape) = c("sample_name","target1_frac","target1_count","target2_frac","target2_count","target3_frac","target3_count")
    }else if (ncol(counts_anchor_reshape) == 5){
      names(counts_anchor_reshape) = c("sample_name","target1_frac","target1_count","target2_frac","target2_count")
    }
    
    counts_anchor_reshape_wo_sample_name = copy(counts_anchor_reshape) # because I need to change all NAs in the data table to 0, I first make a copy by removing sample_name column and then change all NA to 0 in it 
    counts_anchor_reshape_wo_sample_name[,sample_name:=NULL]
    setnafill(counts_anchor_reshape_wo_sample_name,fill=0)
    counts_anchor_reshape = cbind(counts_anchor_reshape$sample_name,counts_anchor_reshape_wo_sample_name)
    names(counts_anchor_reshape)[1] = "sample_name"
    
    
    sample_names = data.table(counts_anchor_reshape$sample_name)
    sample_names = merge(sample_names,counts_anchor[!duplicated(sample_name),list(sample_name,group)],all.x=TRUE,all.y = FALSE,by.x="V1",by.y="sample_name")
    sample_names[,class:=as.numeric(as.factor(group))] # class is the numeric conversion of the groups which is needed for the multinomial GLM
    
    counts_anchor_reshape[,sample_name:=NULL]
    
    if (ncol(counts_anchor_reshape) == 10){
      regression_formula = as.formula( "class ~ target1_frac + target2_frac + target3_frac + target4_frac + other_frac")
    } else if (ncol(counts_anchor_reshape) == 8){
      regression_formula = as.formula( "class ~ target1_frac + target2_frac + target3_frac + target4_frac")
    }else if (ncol(counts_anchor_reshape) == 6){
      regression_formula = as.formula( "class ~ target1_frac + target2_frac + target3_frac")
    }else if (ncol(counts_anchor_reshape) == 4){
      regression_formula = as.formula( "class ~ target1_frac + target2_frac")
    }
    
    
    counts_anchor_reshape = cbind(counts_anchor_reshape,sample_names$group,sample_names$class)
    setnames(counts_anchor_reshape, c("V2","V3"), c("group","class"))
    counts_anchor_reshape = counts_anchor_reshape[!is.na(group)] 
    counts_anchor_reshape[,num_per_group:=.N,by=group]
    counts_anchor_reshape[,weight:=1/num_per_group]
    counts_anchor_reshape = counts_anchor_reshape[num_per_group>5]
    
    # below if there is at least two groups for the anchor we perform GLMnet multinomial regression 
    if (length(unique(counts_anchor_reshape$group))>1){
      x_glmnet = model.matrix(regression_formula, counts_anchor_reshape)
      glmnet_model = cv.glmnet(x_glmnet, as.factor(counts_anchor_reshape$group), family = c("multinomial"), intercept = FALSE, alpha = 1, nlambda = 50, nfolds = 4, weights = counts_anchor_reshape$weight)
      glmnet_coeffs = coef(glmnet_model)
      
      largest_GLM_coefficient = max(unlist(lapply(lapply(glmnet_coeffs,abs),max))) # this will give us the GLM coefficient with the highest magnitude
      # if the largest coefficient >1 then we plot target counts fractions and add it to the output table 
      if (largest_GLM_coefficient > 1){
        metadata_group_names = paste(names(glmnet_coeffs), collapse = "||") # collapse all the group names for this into a string
        GLM_coefficients = paste(lapply(glmnet_coeffs, paste, collapse = ":"),collapse = "||") # collapse all the GLM coefficients into a string
        GLM_output_dt_anchor = cbind(selected_anchors[anchor==anchor_interest], metadata_group_names, GLM_coefficients, largest_GLM_coefficient)
        GLM_output_dt = rbind(GLM_output_dt, GLM_output_dt_anchor)
        
        #generate and write boxplot/scatterplot for the anchor
        pdf(file=paste(directory, "/",run_name,"_supervised_metadata/plots/", anchor_interest, ".pdf", sep = ""), width = 12, height = 6)
        if (ncol(counts_anchor_reshape) ==14){
          long_counts_anchor_reshape <- melt(setDT(counts_anchor_reshape[,list(target1_frac, target2_frac, target3_frac, target4_frac, other_frac, group)]), id.vars = c("group"))
          counts_anchor_reshape_df = data.frame(counts_anchor_reshape[,list(target1_frac,target2_frac,target3_frac,target4_frac,other_frac)])
        } else if (ncol(counts_anchor_reshape) ==12){
          long_counts_anchor_reshape <- melt(setDT(counts_anchor_reshape[,list(target1_frac, target2_frac, target3_frac, target4_frac, group)]), id.vars = c("group"))
          counts_anchor_reshape_df = data.frame(counts_anchor_reshape[,list(target1_frac,target2_frac,target3_frac,target4_frac)])
        } else if (ncol(counts_anchor_reshape) ==10){
          long_counts_anchor_reshape <- melt(setDT(counts_anchor_reshape[,list(target1_frac, target2_frac, target3_frac, group)]), id.vars = c("group"))
          counts_anchor_reshape_df = data.frame(counts_anchor_reshape[,list(target1_frac,target2_frac,target3_frac)])
        } else if(ncol(counts_anchor_reshape) == 8){
          long_counts_anchor_reshape <- melt(setDT(counts_anchor_reshape[,list(target1_frac, target2_frac, group)]), id.vars = c("group"))
          counts_anchor_reshape_df = data.frame(counts_anchor_reshape[,list(target1_frac,target2_frac)])
        } 
        g1 = ggplot(long_counts_anchor_reshape, aes(x=group, y=value, fill=as.factor(variable))) + geom_boxplot() + theme_bw() +ggtitle(anchor_interest)
        g2 = ggplot(counts_anchor_reshape, aes(x = target1_count, y = target2_count, shape = as.factor(group), color = as.factor(group))) + geom_point() + theme_bw()
        
        ## g3 is the heatmap for target fractions per sample
        rownames(counts_anchor_reshape_df) = c(1:nrow(counts_anchor_reshape_df))
        my_annotation_row = data.frame(counts_anchor_reshape$group)
        rownames(my_annotation_row) = rownames(counts_anchor_reshape_df)
        names(my_annotation_row) = "group"
        g3 = pheatmap(counts_anchor_reshape_df,annotation_row = my_annotation_row, show_rownames = FALSE, cluster_cols = FALSE)
        print(grid.arrange(grobs = list(g1,g2,  g3[[4]]),layout_matrix=rbind(c(1,3),c(2,3))))
        dev.off()
      }
    }
  },error=function(e){cat("ERROR :",conditionMessage(e), "\n")})
}
write.table(GLM_output_dt, paste(directory,"/",run_name,"_supervised_metadata/GLM_supervised_anchors.tsv", sep = ""), sep = "\t", row.names = FALSE, quote = FALSE)
######################################################################################
######################################################################################

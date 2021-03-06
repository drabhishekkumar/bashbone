#! /usr/bin/env Rscript
# (c) Konstantin Riege
options(warn=-1)

cat("about to run deseq2 and pca\n")

suppressMessages({
	library("DESeq2")
	library("BiocParallel")
	library("ggplot2")
	library("gplots")
	library("pheatmap")
	library("RColorBrewer")
	library("dplyr")
})

args = commandArgs(TRUE)
threads = as.numeric(args[1])
incsv = args[2] # sample,countfile,condition,replicate[,factor1,factor2,..]
outdir = args[3]
args = args[4:length(args)]
ctr = args[rep(c(T,F),length(args)/2)] # wt t1 wt t2 t1 t2
treat = args[rep(c(F,T),length(args)/2)]

dir.create(outdir, recursive = T, showWarnings = F)
BPPARAM = MulticoreParam(workers = threads)
setEPS(width=8, height=8, onefile=T)


##### deseq


experiments = read.table(incsv, header=T, sep=",", stringsAsFactors=F)
colnames(experiments)[1:4] = c("sample","countfile","condition","replicate")

# create design formula from factors under exclusion of potential linear combinations
# e.g. ~ factor1 + factor2 + condition
get_design = function(experiments){
	factors = c()
	if(length(colnames(experiments)) > 4){
		for (f in colnames(experiments)[5:length(colnames(experiments))]){
			v = experiments[,f]
			# levels(xyxy) -> 2 > 1 && xyxy @ aabb -> a:xy , b:xy -> {x,y} > 0 i.e. no linear combination
			# whereas levels(xxxx) -> 1 and xyzz @ aabb -> a:xy , b:z -> {} == 0 i.e. deseq error
			if (length(levels(as.factor(v))) > 1 && length(Reduce(intersect, split(v,experiments$condition))) > 0){
				factors = c(factors,f)
			}
		}
	}
	return(paste("~",paste(c(factors,"condition"),collapse=" + ")))
}

design = get_design(experiments)
cat(paste("computing pca with deseq normalized read counts based on design formula: ",design,"\n",sep=""))

ddsHTSeq = DESeqDataSetFromHTSeqCount(sampleTable = experiments, directory = "", design = as.formula(design))
dds = DESeq(ddsHTSeq, parallel = TRUE, BPPARAM = BPPARAM)
save(dds, file = file.path(outdir,"dds.Rdata"))

pdf(file.path(outdir,"dispersion.pdf"))
plotDispEsts(dds)
graphics.off()


###### pca


log = DESeqTransform(SummarizedExperiment(log2(counts(dds, normalized=T) + 1), colData=colData(dds)))
save(log, file = file.path(outdir,"log.Rdata"))
vsd = varianceStabilizingTransformation(dds, blind=FALSE)
save(vsd, file = file.path(outdir,"vsd.Rdata"))
rld = rlog(dds, blind=FALSE)
save(rld, file = file.path(outdir,"rld.Rdata"))

for (method in c("log","vsd","rld")){
	# deseq method
	# data = plotPCA(get(normed), intgroup = c("condition", "replicate"), returnData = T)
	# percentVar = round(100 * attr(data, "percentVar"))

	normed = assay(get(method))
	vars = rowVars(normed)
	n = 100
	#n = length(vars)
	topidx = order(vars, decreasing = TRUE)[1:min(n,length(vars))]
	pca = prcomp(t(normed[topidx, ]), scale = F)
	percentVar = round(100*pca$sdev^2/sum(pca$sdev^2),1)
	data = data.frame(PC1 = pca$x[,1], PC2 = pca$x[,2], PC3 = pca$x[,3], PC4 = pca$x[,4], replicate = experiments$replicate, condition = experiments$condition)
	write.table(data.frame(id=rownames(data),data), row.names = F,
		file=file.path(outdir,paste("pca_12_",method,".tsv",sep="")), quote=F, sep="\t"
	)

	suppressMessages({
		ggplot(data, aes(PC1, PC2, color = condition, group = condition, shape = replicate)) +
			ggtitle("PCA plot - PC1 vs PC2") +
			scale_shape_manual(values = c(1:length(unique(data$replicate)) )) +
			coord_fixed() +
			theme_bw() +
			theme(legend.box = "horizontal") +
			geom_point(size = 3) +
			stat_ellipse() +
			xlab(paste0("PC1: ",percentVar[1], "% variance")) +
			ylab(paste0("PC2: ",percentVar[2], "% variance"))
		ggsave(file.path(outdir,paste("pca_12_",method,".pdf",sep="")))

		ggplot(data, aes(PC1, PC3, color = condition, group = condition, shape = replicate)) +
			ggtitle("PCA plot - PC1 vs PC3") +
			scale_shape_manual(values = c(1:length(unique(data$replicate)) )) +
			coord_fixed() +
			theme_bw() +
			theme(legend.box = "horizontal") +
			geom_point(size = 3) +
			stat_ellipse() +
			xlab(paste0("PC1: ",percentVar[1], "% variance")) +
			ylab(paste0("PC3: ",percentVar[3], "% variance"))
		ggsave(file.path(outdir,paste("pca_13_",method,".pdf",sep="")))

		ggplot(data, aes(PC2, PC3, color = condition, group = condition, shape = replicate)) +
			ggtitle("PCA plot - PC2 vs PC3") +
			scale_shape_manual(values = c(1:length(unique(data$replicate)) )) +
			coord_fixed() +
			theme_bw() +
			theme(legend.box = "horizontal") +
			geom_point(size = 3) +
			stat_ellipse() +
			xlab(paste0("PC2: ",percentVar[2], "% variance")) +
			ylab(paste0("PC3: ",percentVar[3], "% variance"))
		ggsave(file.path(outdir,paste("pca_23_",method,".pdf",sep="")))
	})
}


##### heatmap functions


gplots_heatmap = function(){
	if(min(df)<0) {
		# use red (-) and blue (+)
		color = colorRampPalette(brewer.pal(9, "RdBu"))(100)
		# define breaks from min to 0 and 0 to max according to number colors/2
		breaks = c(seq(min(df), 0, length.out=51), seq(max(df)/100, max(df), length.out=50))
		keylabel = "Z-score "
	} else {
		# use simple gradient
		color = colorRampPalette(brewer.pal(9, "GnBu"))(100)
		# define breaks equal to heatmap default
		breaks = seq(min(df), max(df), length.out=101)
		keylabel = "VSC "
	}

	# get number conditions colors and repeat them according to colannotation
	colannotationcolor = colorRampPalette(brewer.pal(3, "Blues"))(length(unique(colannotation)))
	j=0
	colannotationcolor.full=c()
	for (g in unique(colannotation)){
		j=full_join+1
		colannotationcolor.full=c(colannotationcolor.full,rep(colannotationcolor[j],length(colannotation[colannotation %in% g])))
	}

	m = as.matrix(df)
	rownames(m) = rownames(df)

	postscript(paste0(path,".localclust.ps"))
	par(mar=c(0,0,0,0))
	# par(mar=c(0,0,4.2,0)) if topleft, to put legend below key
	heatmap.2(m, col = color, Rowv = T, Colv = coldendro, dendrogram = "both",
		breaks = breaks, colsep = colsep, sepcolor="black", sepwidth=0.01,
		trace = "none", margin = c(8, 8), lhei=c(1,6), lwid=c(1,3),
		symkey = F, key.title = NA, key.ylab = NA, key.par = list(cex=0.6), density.info="none", key.xlab = keylabel,
		cexRow = 0.8, cexCol = 0.9, srtCol=45,
		ColSideColors = colannotationcolor.full
	)
	legend("topright", inset = c(0.01,0), legend=unique(colannotation), col=colannotationcolor, lty = 1, lwd = 8, cex=0.72, bty="n", title="Group")
	# coords <- locator(1)      + mouse click , then use values e.g x=0 and y=1 (topleft) instead of keywords
	graphics.off()
}


get_heatmap = function(input,path){
	# perform inner-group column clustering

	colclustlist = list()
	#for (condition in unique(experiments$condition)) {
	for (condition in c(ctr[i],treat[i])) {
		m = as.matrix(input[ , colnames(input) %in% gsub("\\W",".",experiments$sample[experiments$condition %in% condition]) ])
		rownames(m) = input$id

		# dist(df, method = "euclidean")
		# hclust(df, method = "complete")
		colclust = hclust(dist(t(m)))
		m = m[ , colclust$order]

		if(length(colclustlist)==0){
			df = data.frame(id=rownames(m),m)
			colclustlist = list(colclust)
			colsep = ncol(m)
			colannotation = rep(condition,ncol(m))
		} else {
			df = full_join(df, data.frame(id=rownames(m),m), by = 'id')
			colclustlist = c(colclustlist, list(colclust))
			colsep = c(colsep,tail(colsep,1)+ncol(m))
			colannotation = c(colannotation,rep(condition,ncol(m)))
		}
	}

	# remove last separator (for gplots) and id-column
	colsep = colsep[1:length(colsep)-1]
	df = df[,2:length(df)]
	rownames(df) = input$id

	# merge dendrograms
	# multiforcation at +10% height, i.e. merge( as.dendrogram(colclustlist[[1]]) , as.dendrogram(colclustlist[[2]]), as.dendrogram(colclustlist[[3]]) )
	# can be handled by gplots, but not converted to hclust object, due to missing binary list structure
	# coldendro = do.call(merge, lapply(colclustlist, function(x) as.dendrogram(x)))
	# binary
	# coldendro = Reduce(merge, lapply(colclustlist, function(x) as.dendrogram(x)))
	# binary at same heights
	maxheight = max(unlist(lapply(colclustlist, function(x) max(x$height))))
	maxheight = maxheight + maxheight/10
	coldendro = Reduce(function(x, y) merge(x, y, height = maxheight), lapply(colclustlist, function(x) as.dendrogram(x)))
	# convert to hclust object for pheatmap
	colclust = as.hclust(coldendro)


	###### heatmap.2

	# alternative to play with
	# gplots_heatmap

	###### pheatmap

	if(min(df)<0) {
		# use red (-) and blue (+)
		color = colorRampPalette(brewer.pal(9, "RdBu"))(100)
		# define breaks from min to 0 and 0 to max according to number colors/2
		breaks = c(seq(min(df), 0, length.out=51), seq(max(df)/100, max(df), length.out=50))
		# define breaks around 0 and labels
		legendbreaks = unique(c(seq(min(df), 0, length.out = round(-min(df)+1)) , seq(0, max(df), length.out = round(max(df)+1))))
		legendlabels = round(legendbreaks)
		legendlabels[legendlabels==0] = "Z-score "
	} else {
		# use simple gradient
		color = colorRampPalette(brewer.pal(9, "GnBu"))(100)
		# define breaks equal to heatmap default
		breaks = seq(min(df), max(df), length.out=101)
		# define breaks and labels
		legendbreaks = seq(min(df), max(df), length.out=7)
		legendlabels = round(legendbreaks)
		legendlabels[1] = "VSC "
	}

	# get number conditions colors and name them by conditions
	colannotationcolor = colorRampPalette(brewer.pal(3, "Blues"))(length(unique(colannotation)))
	names(colannotationcolor) = unique(colannotation)
	# create dataframe of column annotations with rownames
	colannotations = data.frame(row.names = colnames(df), Group = colannotation)
	# create list of annotation colors according to dataframes of column and or row annotations
	annotationcolors = list(Group = colannotationcolor)

	p = pheatmap(df, color = color,	cluster_rows = T, cluster_cols = colclust, cutree_cols = length(colclustlist),
			annotation_col = colannotations, annotation_colors = annotationcolors, annotation_names_col = F,
			border_color = NA,  fontsize_row = 7, fontsize_col = 7, angle_col = 45,
			breaks = breaks, legend_breaks = legendbreaks, legend_labels = legendlabels,
			main = paste0("Heatmap of ",nrow(df)," most differentially expressed genes\n")
	)
	# filename = "/../../png|pdf|tiff|bmp"
	# workaround to store figure as different file type - use ps to later replace row and column names + ps2pdf
	postscript(paste0(path,".localclust.ps"))
	grid::grid.newpage()
	grid::grid.draw(p$gtable)
	graphics.off()


	# default like column clustered heatmap

	p = pheatmap(df, color = color, cluster_rows = T, cluster_cols = T,
		annotation_col = colannotations, annotation_colors = annotationcolors, annotation_names_col = F,
		border_color = NA,  fontsize_row = 7, fontsize_col = 7, angle_col = 45,
		breaks = breaks, legend_breaks = legendbreaks, legend_labels = legendlabels,
		main =paste0("Heatmap of ",nrow(df)," most differentially expressed genes\n")
	)
	postscript(paste0(path,".globalclust.ps"))
	grid::grid.newpage()
	grid::grid.draw(p$gtable)
	graphics.off()
}


get_heatmap_mean = function(input,path){
	# remove id-column
	df = input[,2:length(input)]
	rownames(df) = input$id

	if(min(df)<0) {
		# use red (-) and blue (+)
		color = colorRampPalette(brewer.pal(9, "RdBu"))(100)
		# define breaks from min to 0 and 0 to max according to number colors/2
		breaks = c(seq(min(df), 0, length.out=51), seq(max(df)/100, max(df), length.out=50))
		# define breaks around 0 and labels
		legendbreaks = unique(c(seq(min(df), 0, length.out = round(-min(df)+1)) , seq(0, max(df), length.out = round(max(df)+1))))
		legendlabels = round(legendbreaks)
		legendlabels[legendlabels==0] = "Z-score "
	} else {
		# use simple gradient
		color = colorRampPalette(brewer.pal(9, "GnBu"))(100)
		# define breaks equal to heatmap default
		breaks = seq(min(df), max(df), length.out=101)
		# define breaks and labels
		legendbreaks = seq(min(df), max(df), length.out=7)
		legendlabels = round(legendbreaks)
		legendlabels[1] = "VSC "
	}

	p = pheatmap(df, color = color, cluster_rows = T, cluster_cols = F,
			border_color = NA,  fontsize_row = 7, fontsize_col = 7, angle_col = 45,
			breaks = breaks, legend_breaks = legendbreaks, legend_labels = legendlabels,
			main = paste0("Heatmap of ",nrow(df)," most differentially expressed genes\n")
	)
	# filename = "/../../png|pdf|tiff|bmp"
	# workaround to store figure as different file type - use ps to later replace row and column names + ps2pdf
	postscript(paste0(path,".ps"))
	grid::grid.newpage()
	grid::grid.draw(p$gtable)
	graphics.off()
}


###### fetch pairwise deseq results and plot heatmaps


get_table = function(dds){
	ddsr = results(dds, contrast=c("condition",treat[i],ctr[i]), parallel = TRUE, BPPARAM = BPPARAM)

	ddsr = ddsr[order(ddsr$padj) , ]
	write.table(data.frame(id=rownames(ddsr),ddsr), row.names = F,
		file=file.path(odir,"deseq.full.tsv"), quote=F, sep="\t"
	)

	ddsr = ddsr[!is.na(ddsr$log2FoldChange) , ]
	ddsr = ddsr[!is.na(ddsr$padj) , ]
	ddsr = ddsr[ddsr$baseMean > 0 , ]
	ddsr = ddsr[rev(order(abs(ddsr$log2FoldChange))) , ]
	write.table(data.frame(id=rownames(ddsr),ddsr), row.names = F,
		file=file.path(odir,"deseq.noNA.tsv"), quote=F, sep="\t"
	)

	ddsr = ddsr[ddsr$padj <= 0.05 , ]
	write.table(data.frame(id=rownames(ddsr),ddsr), row.names = F,
		file=file.path(odir,"deseq.tsv"), quote=F, sep="\t"
	)

	if(nrow(ddsr)>0){
		pdf(file.path(odir,"ma_plot.pdf"))
		plotMA(ddsr)
		graphics.off()
	}

	rldr = rld[,rld$condition %in% c(ctr[i],treat[i])]
	data = plotPCA(rldr, intgroup = c("condition", "replicate"), returnData = T)
	write.table(data.frame(id=rownames(data),data), row.names = F,
		file=file.path(odir,"pca.tsv"), quote=F, sep="\t"
	)
	percentVar = round(100 * attr(data, "percentVar"))

	suppressMessages({
		ggplot(data, aes(PC1, PC2, color = condition, group = condition, shape = replicate)) +
			ggtitle(paste("PC1 vs PC2: ", length(rownames(rldr)), " genes")) +
			scale_shape_manual(values = c(1:length(unique(data$replicate)) )) +
			coord_fixed() +
			theme_bw() +
			theme(legend.box = "horizontal") +
			geom_point(size = 3) +
			stat_ellipse() +
			xlab(paste("PC1:",percentVar[1],"% variance",sep=" ")) +
			ylab(paste("PC2:",percentVar[2],"% variance",sep=" "))
		ggsave(file.path(odir,"pca.pdf"))
	})

	vsdr = vsd[,vsd$condition %in% c(ctr[i],treat[i])]

	vsc = as.data.frame(assay(vsdr))
	write.table(data.frame(id=rownames(vsc),vsc), row.names = F,
		file=file.path(odir,"experiments.vsc"), quote=F, sep="\t"
	)
	zscores = log(vsc+1)
	zscores = zscores-rowMeans(zscores)
	zscores = zscores/apply(zscores,1,sd)
	zscores[is.na(zscores)] = 0
	write.table(data.frame(id=rownames(zscores),zscores), row.names = F,
		file=file.path(odir,"experiments.vsc.zscores"), quote=F, sep="\t"
	)

	colnamesvsc = colnames(vsc)
	colnames(vsc) = as.vector(vsdr$condition)
	meanvsc = t(apply(vsc, 1, function(x) tapply(x, colnames(vsc), mean)))
	meanvsc = meanvsc[,c(ctr[i],treat[i])]
	colnames(vsc) = colnamesvsc
	write.table(data.frame(id=rownames(meanvsc),meanvsc), row.names = F,
		file = file.path(odir,"experiments.mean.vsc"), quote=F, sep="\t"
	)
	meanzscores = log(meanvsc+1)
	meanzscores = meanzscores-rowMeans(meanzscores)
	meanzscores = meanzscores/apply(meanzscores,1,sd)
	meanzscores[is.na(meanzscores)] = 0
	write.table(data.frame(id=rownames(meanzscores),meanzscores), row.names = F,
		file=file.path(odir,"experiments.mean.vsc.zscores"), quote=F, sep="\t"
	)

	if(nrow(ddsr)>1){
		color = colorRampPalette(brewer.pal(9, "GnBu"))(100)
		topids = rownames(ddsr)[1:min(50,nrow(ddsr))]

		vsc = vsc[rownames(vsc) %in% topids , ]
		write.table(data.frame(id=rownames(vsc),vsc), row.names = F,
			file=file.path(odir,"heatmap.vsc"), quote=F, sep="\t"
		)
		get_heatmap(data.frame(id=rownames(vsc),vsc),file.path(odir,"heatmap.vsc"))

		zscores = zscores[rownames(zscores) %in% topids , ]
		write.table(data.frame(id=rownames(zscores),zscores), row.names = F,
			file=file.path(odir,"heatmap.vsc.zscores"), quote=F, sep="\t"
		)
		get_heatmap(data.frame(id=rownames(zscores),zscores),file.path(odir,"heatmap.vsc.zscores"))

		meanvsc = meanvsc[rownames(meanvsc) %in% topids , ]
		write.table(data.frame(id=rownames(meanvsc),meanvsc), row.names = F,
			file = file.path(odir,"heatmap.mean.vsc"), quote=F, sep="\t"
		)
		get_heatmap_mean(data.frame(id=rownames(meanvsc),meanvsc),file.path(odir,"heatmap.mean.vsc"))

		meanzscores = meanzscores[rownames(meanzscores) %in% topids , ]
		write.table(data.frame(id=rownames(meanzscores),meanzscores), row.names = F,
			file = file.path(odir,"heatmap.mean.vsc.zscores"), quote=F, sep="\t"
		)
		get_heatmap_mean(data.frame(id=rownames(meanzscores),meanzscores),file.path(odir,"heatmap.mean.vsc.zscores"))
	}

	cat(paste("number of significantly differentially expressed genes for ",ctr[i]," vs ",treat[i]," :",nrow(ddsr),"\n",sep=""))
}


##### iterate over pairs of conditions, recompute diff expr. according to experiment factors, get deseq results + vsc + z-scores + heatmaps


for (i in 1:length(ctr)){
	odir = file.path(outdir,paste(ctr[i],"-vs-",treat[i],sep=""))
	dir.create(odir, recursive = T, showWarnings = F)

	thisexperiments = experiments[experiments$condition %in% c(ctr[i],treat[i]),]
	thisdesign = get_design(thisexperiments)

	if (design != thisdesign){
		cat(paste("warning: executing ",ctr[i]," vs ",treat[i]," independently from other samples with design formula: ",thisdesign,"\n",sep=""))
		ddsHTSeq = DESeqDataSetFromHTSeqCount(sampleTable = thisexperiments, directory = "", design = as.formula(thisdesign))
		thisdds = DESeq(ddsHTSeq, parallel = TRUE, BPPARAM = BPPARAM)
		save(thisdds, file = file.path(odir,"dds.Rdata"))
		get_table(thisdds)
	} else {
		cat(paste("executing ",ctr[i]," vs ",treat[i]," with design formula: ",design,"\n",sep=""))
		get_table(dds)
	}
}

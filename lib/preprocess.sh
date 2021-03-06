#! /usr/bin/env bash
# (c) Konstantin Riege

preprocess::fastqc() {
	_cleanup::preprocess::fastqc(){
		rm -rf "${tdirs[@]}"
	}

	_usage() {
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[1]} usage:
			-S <hardskip> | true/false return
			-s <softskip> | true/false only print commands
			-t <threads>  | number of
			-o <outdir>   | path to
			-p <tmpdir>   | path to
			-1 <fastq1>   | array of
			-2 <fastq2>   | array of
		EOF
		return 1
	}

	local OPTIND arg mandatory skip=false threads outdir tmpdir
	declare -n _fq1_fastqc _fq2_fastqc
	while getopts 'S:s:t:p:o:1:2:' arg; do
		case $arg in
			S) $OPTARG && return 0;;
			s) $OPTARG && skip=true;;
			t) ((++mandatory)); threads=$OPTARG;;
			p) ((++mandatory)); tmpdir="$OPTARG"; mkdir -p "$tmpdir";;
			o) ((++mandatory)); outdir="$OPTARG"; mkdir -p "$outdir";;
			1) ((++mandatory)); _fq1_fastqc=$OPTARG;;
			2) _fq2_fastqc=$OPTARG;;
			*) _usage;;
		esac
	done
	[[ $mandatory -lt 4 ]] && _usage

	commander::printinfo "calculating qualities"

	declare -a cmd1 tdirs
	local f
	for f in {"${_fq1_fastqc[@]}","${_fq2_fastqc[@]}"}; do
		tdirs+=("$(mktemp -d -p "$tmpdir" cleanup.XXXXXXXXXX.fastqc)")
		commander::makecmd -a cmd1 -s '|' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- 'CMD'
			fastqc
			-d "${tdirs[-1]}"
			-outdir "$outdir"
			"$f" 2>&1
		CMD
			sed -u '${/Analysis complete/!{q 1}}'
		CMD
	done

	if $skip; then
		commander::printcmd -a cmd1
	else
		commander::runcmd -c fastqc -v -b -t $threads -a cmd1
	fi

	return 0
}

preprocess::rmpolynt(){
	_usage() {
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[1]} usage:
			-S <hardskip> | true/false return
			-s <softskip> | true/false only print commands
			-t <threads>  | number of
			-o <outdir>   | path to
			-1 <fastq1>   | array of
			-2 <fastq2>   | array of
		EOF
		return 1
	}

	local OPTIND arg mandatory skip=false threads outdir
	declare -n _fq1_rmpolynuc _fq2_rmpolynuc
	while getopts 'S:s:a:A:t:o:1:2:' arg; do
		case $arg in
			S) $OPTARG && return 0;;
			s) $OPTARG && skip=true;;
			t) ((++mandatory)); threads=$OPTARG;;
			o) ((++mandatory)); outdir="$OPTARG"; mkdir -p "$outdir";;
			1) ((++mandatory)); _fq1_rmpolynuc=$OPTARG;;
			2) _fq2_rmpolynuc=$OPTARG;;
			*) _usage;;
		esac
	done
	[[ $mandatory -lt 3 ]] && _usage

	commander::printinfo "clipping poly N-, mono- and di-nucleotide ends"

	# -a ADAPTERX : allows partial matches, but disallow internal matches
	# -a ADAPTER$ : adapter will only be found if it is a true suffix of the read
	declare -a poly
	local i
	for i in A C G T; do
		poly+=("$(printf "$i%.0s" {1..100})X")
	done
	for i in AB CD GH TV; do #iupac
		poly+=("$(printf "$i%.0s" {1..100})X")
	done

	preprocess::cutadapt \
		-S false \
		-s $skip \
		-a poly \
		-A poly \
		-t $threads \
		-o "$outdir" \
		-1 _fq1_rmpolynuc \
		-2 _fq2_rmpolynuc

	return 0
}

preprocess::cutadapt(){
	_usage() {
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[1]} usage:
			-S <hardskip> | true/false return
			-s <softskip> | true/false only print commands
			-a <adapter1> | array of
			-A <adapter2> | array of
			-t <threads>  | number of
			-o <outdir>   | path to
			-1 <fastq1>   | array of
			-2 <fastq2>   | array of
		EOF
		return 1
	}

	local OPTIND arg mandatory skip=false threads outdir
	declare -n _adaptera_cutadapt _adapterA_cutadapt _fq1_cutadapt _fq2_cutadapt
	while getopts 'S:s:a:A:t:o:1:2:' arg; do
		case $arg in
			S) $OPTARG && return 0;;
			s) $OPTARG && skip=true;;
			a) ((++mandatory)); _adaptera_cutadapt=$OPTARG;;
			A) _adapterA_cutadapt=$OPTARG;;
			t) ((++mandatory)); threads=$OPTARG;;
			o) ((++mandatory)); outdir="$OPTARG"; mkdir -p "$outdir";;
			1) ((++mandatory)); _fq1_cutadapt=$OPTARG;;
			2) _fq2_cutadapt=$OPTARG;;
			*) _usage;;
		esac
	done
	[[ $mandatory -lt 4 ]] && _usage

	commander::printinfo "adapter clipping"

	local instances ithreads
	# parallelized cutadapt is faster on parallel data than max threads -> use max 10 per instance
	# cutadapt cannot handle more than 64 threads
	read -r instances ithreads < <(configure::instances_by_threads -i ${#_fq1_cutadapt[@]} -t 10 -T $threads)

	declare -a cmd1 cmd2
	local i o1 o2 n=$((${#_adaptera_cutadapt[@]}))
	[[ $n -gt 2 ]] && n=2 # since only the best matching adapter is removed, run cutadapt twice
	for i in "${!_fq1_cutadapt[@]}"; do
		o1="$outdir"/$(basename "${_fq1_cutadapt[$i]}")
		o2="$outdir"/$(basename "${_fq2_cutadapt[$i]}")
		if [[ "${_fq2_cutadapt[$i]}" ]]; then
			commander::makecmd -a cmd1 -s '|' -c {COMMANDER[0]}<<- CMD
				cutadapt
				${_adaptera_cutadapt[@]/#/-a }
				${_adapterA_cutadapt[@]/#/-A }
				-n $n
				--trim-n
				-j $ithreads
				-m 18
				-O 5
				-o "$o1"
				-p "$o2"
				"${_fq1_cutadapt[$i]}" "${_fq2_cutadapt[$i]}"
			CMD
			helper::makezipcmd -a cmd2 -t $threads -c "${_fq1_cutadapt[$i]}" -c "${_fq2_cutadapt[$i]}" -z o1 -z o2
			_fq1_cutadapt[$i]="$o1"
			_fq2_cutadapt[$i]="$o2"
		else
			commander::makecmd -a cmd1 -s '|' -c {COMMANDER[0]}<<- CMD
				cutadapt
				${_adaptera_cutadapt[@]/#/-a }
				-n $n
				--trim-n
				-j $threads
				-m 18
				-O 5
				-o "$o1"
				"${_fq1_cutadapt[$i]}"
			CMD
			helper::makezipcmd -a cmd2 -t $threads -c "${_fq1_cutadapt[$i]}" -z o1
			_fq1_cutadapt[$i]="$o1"
		fi
	done

	if $skip; then
		commander::printcmd -a cmd1
		commander::printcmd -a cmd2
	else
		commander::runcmd -c cutadapt -v -b -t $instances -a cmd1
		commander::runcmd -v -b -t $instances -a cmd2
	fi

	return 0
}

preprocess::trimmomatic() {
	_usage() {
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[1]} usage:
			-S <hardskip> | true/false return
			-s <softskip> | true/false only print commands
			-t <threads>  | number of
			-o <outdir>   | path to
			-p <tmpdir>   | path to
			-1 <fastq1>   | array of
			-2 <fastq2>   | array of
		EOF
		return 1
	}

	local OPTIND arg mandatory skip=false threads outdir tmpdir
	declare -n _fq1_trimmomatic _fq2_trimmomatic
	while getopts 'S:s:t:m:o:p:1:2:' arg; do
		case $arg in
			S) $OPTARG && return 0;;
			s) $OPTARG && skip=true;;
			t) ((++mandatory)); threads=$OPTARG;;
			o) ((++mandatory)); outdir="$OPTARG"; mkdir -p "$outdir";;
			p) ((++mandatory)); tmpdir="$OPTARG"; mkdir -p "$tmpdir";;
			1) ((++mandatory)); _fq1_trimmomatic=$OPTARG;;
			2) _fq2_trimmomatic=$OPTARG;;
			*) _usage;;
		esac
	done
	[[ $mandatory -lt 4 ]] && _usage

	commander::printinfo "trimming"

	#offset 64: ASCII 64 to 106 (solexa: 59 to 106)
	#offset 33: ASCII 33 to 75
	#64 to 33: ord(char)-33+2
	#theoretical max range is 126 for all encodings, thus more reliable detection would be just min based
	#https://www.ncbi.nlm.nih.gov/pmc/articles/PMC2847217/
	#https://www.drive5.com/usearch/manual/quality_score.html
	#od -v -A n -t u1
	declare -a cmd1
	local f catcmd
	for f in "${_fq1_trimmomatic[@]}"; do
		helper::makecatcmd -c catcmd -f $f
		commander::makecmd -a cmd1 -s ' ' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- 'CMD' {COMMANDER[2]}<<- CMD
			$catcmd $f | head -4000
		CMD
			| perl -M'List::Util qw(min max)' -slne '
				BEGIN{
					$min=106
				}
				if($.%4==0){
					@x=unpack"C*";
					$min=min($min,@x);
					$max=max($max,@x);
				}
				END{
					if($min>=33 && $max<=75){
						print "phred33 $f";
					}elsif($min>=64 && $max>75 && $max<=106){
						print "phred64 $f";
					}elsif($min>=59 && $min<64 && $max>75 && $max<=106){
						print "solexa64 $f";
					}else{
						print "unknown $f";
					}
				}
			'
		CMD
			-- -f="$f"
		CMD
	done

	declare -A phred
	local l
	declare -a a mapdata
	commander::printcmd -a cmd1
	mapfile -t mapdata < <(commander::runcmd -t $threads -a cmd1)
	for l in "${mapdata[@]}"; do
		a=($l)
		phred["${a[@]:1}"]="${a[0]}"
	done

	local instances ithreads jmem jgct jcgct
	read -r instances ithreads jmem jgct jcgct < <(configure::jvm -i ${#_fq1_trimmomatic[@]} -T $threads)

	# trimmomatic bottleneck are number of used compression threads (4) - thus use pigz
	declare -a cmd2 cmd3
	local i o1 o2 e1 e2
	for i in "${!_fq1_trimmomatic[@]}"; do
		helper::basename -f "${_fq1_trimmomatic[$i]}" -o o1 -e e1
		e1=$(echo $e1 | cut -d '.' -f 1)
		os1="$outdir/singletons.$o1.$e1.gz"
		o1="$outdir/$o1.$e1.gz"

		if [[ ${_fq2_trimmomatic[$i]} ]]; then
			helper::basename -f "${_fq2_trimmomatic[$i]}" -o o2 -e e2
			e2=$(echo $e2 | cut -d '.' -f 1)
			os2="$outdir/singletons.$o2.$e2.gz"
			o2="$outdir/$o2.$e2.gz"

			commander::makecmd -a cmd2 -s '|' -c {COMMANDER[0]}<<- CMD
				trimmomatic
				-Xmx${jmem}m
				-XX:ParallelGCThreads=$jgct
				-XX:ConcGCThreads=$jcgct
				-Djava.io.tmpdir="$tmpdir"
				PE
				-threads $ithreads
				-${phred["${_fq1_trimmomatic[$i]}"]}
				"${_fq1_trimmomatic[$i]}" "${_fq2_trimmomatic[$i]}"
				>(pigz -p $ithreads -c > "$o1") >(pigz -p $ithreads -c > "$os1")
				>(pigz -p $ithreads -c > "$o2") >(pigz -p $ithreads -c > "$os2")
				SLIDINGWINDOW:5:22
				MINLEN:18
				TOPHRED33
			CMD
			_fq1_trimmomatic[$i]="$o1"
			_fq2_trimmomatic[$i]="$o2"
		else
			commander::makecmd -a cmd2 -s '|' -c {COMMANDER[0]}<<- CMD
				trimmomatic
				-Xmx${jmem}m
				-XX:ParallelGCThreads=$jgct
				-XX:ConcGCThreads=$jcgct
				-Djava.io.tmpdir="$tmpdir"
				SE
				-threads $ithreads
				-${phred["${_fq1_trimmomatic[$i]}"]}
				"${_fq1_trimmomatic[$i]}"
				>(pigz -p $ithreads -c > "$o1")
				SLIDINGWINDOW:5:22
				MINLEN:18
				TOPHRED33
			CMD
			_fq1_trimmomatic[$i]="$o1"
		fi
	done

	if $skip; then
		commander::printcmd -a cmd2
	else
		commander::runcmd -v -b -t $instances -a cmd2
	fi

	return 0
}

preprocess::rcorrector(){
	declare -a tdirs
	_cleanup::preprocess::rcorrector(){
		rm -rf "${tdirs[@]}"
	}

	_usage() {
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[1]} usage:
			-S <hardskip> | true/false return
			-s <softskip> | true/false only print commands
			-t <threads>  | number of
			-o <outdir>   | path to
			-p <tmpdir>   | path to
			-1 <fastq1>   | array of
			-2 <fastq2>   | array of
		EOF
		return 1
	}

	local OPTIND arg mandatory skip=false threads outdir tmpdir
	declare -n _fq1_rcorrector _fq2_rcorrector
	while getopts 'S:s:t:o:p:1:2:' arg; do
		case $arg in
			S) $OPTARG && return 0;;
			s) $OPTARG && skip=true;;
			t) ((++mandatory)); threads=$OPTARG;;
			o) ((++mandatory)); outdir="$OPTARG"; mkdir -p "$outdir";;
			p) ((++mandatory)); tmpdir="$OPTARG"; mkdir -p "$tmpdir";;
			1) ((++mandatory)); _fq1_rcorrector=$OPTARG;;
			2) _fq2_rcorrector=$OPTARG;;
			*) _usage;;
		esac
	done
	[[ $mandatory -lt 4 ]] && _usage

	commander::printinfo "correcting read errors"

	declare -a cmd1 cmd2
	local i o1 b1 e1 o2 b2 e2
	for i in "${!_fq1_rcorrector[@]}"; do
		o1="$outdir"/$(basename "${_fq1_rcorrector[$i]}")
		helper::basename -f "${_fq1_rcorrector[$i]}" -o b1 -e e1
		b1="$outdir"/"$b1"
		tdirs+=("$(mktemp -d -p "$tmpdir" cleanup.XXXXXXXXXX.rcorrector)")
		if [[ ${_fq2_rcorrector[$i]} ]]; then
			o2="$outdir"/$(basename "${_fq2_rcorrector[$i]}")
			helper::basename -f "${_fq2_rcorrector[$i]}" -o b2 -e e2
			b2="$outdir"/"$b2"

			commander::makecmd -a cmd1 -s '&&' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- CMD {COMMANDER[2]}<<- CMD {COMMANDER[3]}<<- CMD
				cd "${tdirs[-1]}"
			CMD
				run_rcorrector.pl
				-1 "${_fq1_rcorrector[$i]}"
				-2 "${_fq2_rcorrector[$i]}"
				-od "$outdir"
				-t $threads
			CMD
				mv "$b1".cor.fq* "$o1"
			CMD
				mv "$b2".cor.fq* "$o2"
			CMD

			helper::makezipcmd -a cmd2 -t $threads -c "${_fq1_rcorrector[$i]}" -c "${_fq2_rcorrector[$i]}" -z o1 -z o2
			_fq1_rcorrector[$i]="$o1"
			_fq2_rcorrector[$i]="$o2"
		else
			commander::makecmd -a cmd1 -s '&&' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- CMD {COMMANDER[2]}<<- CMD
				cd "${tdirs[-1]}"
			CMD
				run_rcorrector.pl
				-s "${_fq1_rcorrector[$i]}"
				-od "$outdir"
				-t $threads
			CMD
				mv "$b1".cor.fq* "$o1"
			CMD

			helper::makezipcmd -a cmd2 -t $threads -c "${_fq1_rcorrector[$i]}" -z o1
			_fq1_rcorrector[$i]="$o1"
		fi
	done

	if $skip; then
		commander::printcmd -a cmd1
		commander::printcmd -a cmd2
	else
		commander::runcmd -c rcorrector -v -b -t 1 -a cmd1
		commander::runcmd -v -b -t 1 -a cmd2
	fi

	return 0
}

preprocess::sortmerna(){
	declare -a tdirs
	_cleanup::preprocess::sortmerna(){
		rm -rf "${tdirs[@]}"
	}

	_usage() {
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[1]} usage:
			-S <hardskip> | true/false return
			-s <softskip> | true/false only print commands
			-t <threads>  | number of
			-m <memory>   | amount of
			-i <insdir>   | base path to
			-o <outdir>   | path to
			-p <tmpdir>   | path to
			-1 <fastq1>   | array of
			-2 <fastq2>   | array of
		EOF
		return 1
	}

	local OPTIND arg mandatory skip=false threads memory outdir tmpdir
	declare -n _fq1_sortmerna _fq2_sortmerna
	while getopts 'S:s:t:m:i:o:p:1:2:' arg; do
		case $arg in
			S) $OPTARG && return 0;;
			s) $OPTARG && skip=true;;
			t) ((++mandatory)); threads=$OPTARG;;
			m) ((++mandatory)); memory=$OPTARG;;
			o) ((++mandatory)); outdir="$OPTARG"; mkdir -p "$outdir";;
			p) ((++mandatory)); tmpdir="$OPTARG"; mkdir -p "$tmpdir";;
			1) ((++mandatory)); _fq1_sortmerna=$OPTARG;;
			2) _fq2_sortmerna=$OPTARG;;
			*) _usage;;
		esac
	done
	[[ $mandatory -lt 5 ]] && _usage

	commander::printinfo "filtering rRNA fragments"

	local instances ithreads
	read -r instances ithreads < <(configure::instances_by_memory -T $threads -m $memory)

	local insdir=$(dirname $(dirname $(which sortmerna)))
	local sortmernaref=$(for i in $insdir/rRNA_databases/*.fasta; do echo $i,$insdir/index/$(basename $i .fasta)-L18; done | xargs -echo | sed 's/ /:/g')

	declare -a cmd1 cmd2 cmd3
	local i catcmd tmp o1 o2 or1 or2 b1 b2 e1 e2 instances=$threads
	for i in "${!_fq1_sortmerna[@]}"; do
		helper::basename -f "${_fq1_sortmerna[$i]}" -o b1 -e e1
		e1=${e1%.*} # trim potential compressing extension
		tdirs+=("$(mktemp -d -p "$tmpdir" cleanup.XXXXXXXXXX.sortmerna)")
		tmp="${tdirs[-1]}/tmp.$b1.$e1"
		tmpo="${tdirs[-1]}/$b1"
		tmpr="${tdirs[-1]}/rRNA.$b1"
		o1="$outdir/$b1.$e1.gz"
		or1="$outdir/rRNA.$b1.$e1.gz"

		# sortmerna v2.1 input must not be compressed (v.3.* creates empty files)
		# outfile gets extension from input file
		# in.fq.bz2 > in.fq + rRNA.out|out -> rRNA.out.fq|out.fq -> rRNA.out.fq.gz|out.fq.gz
		if [[ ${_fq2_sortmerna[$i]} ]]; then
			helper::basename -f "${_fq2_sortmerna[$i]}" -o b2 -e e2
			e2=${e2%.*}
			o2="$outdir/$b2.$e2.gz"
			or2="$outdir/rRNA.$b2.$e2.gz"

			commander::makecmd -a cmd1 -s '|' -c {COMMANDER[0]}<<- CMD
				mergefq.sh
				-t $ithreads
				-m ${memory}M
				-d "${tdirs[-1]}"
				-i "${_fq1_sortmerna[$i]}"
				-j "${_fq2_sortmerna[$i]}"
				-o "$tmp"
			CMD
			commander::makecmd -a cmd2 -s '|' -c {COMMANDER[0]}<<- CMD
				sortmerna
				--ref "$sortmernaref"
				--reads "$tmp"
				--fastx
				--paired_out
				--aligned "$tmpr"
				--other "$tmpo"
				-a $threads
			CMD
			commander::makecmd -a cmd3 -s '|' -c {COMMANDER[0]}<<- CMD
				mergefq.sh
				-t $threads
				-u 1
				-i "$tmpo".$e1
				-z
				-o "$o1"
			CMD
			commander::makecmd -a cmd3 -s '|' -c {COMMANDER[0]}<<- CMD
				mergefq.sh
				-t $threads
				-u 2
				-i "$tmpo".$e2
				-z
				-o "$o2"
			CMD
			commander::makecmd -a cmd3 -s '|' -c {COMMANDER[0]}<<- CMD
				mergefq.sh
				-t $threads
				-u 1
				-i "$tmpr".$e1
				-z
				-o "$or1"
			CMD
			commander::makecmd -a cmd3 -s '|' -c {COMMANDER[0]}<<- CMD
				mergefq.sh
				-t $threads
				-u 2
				-i "$tmpr".$e2
				-z
				-o "$or2"
			CMD
			_fq1_sortmerna[$i]="$o1"
			_fq2_sortmerna[$i]="$o2"
		else
			instances=$threads

			helper::makecatcmd -c catcmd -f "${_fq1_sortmerna[$i]}"
			[[ $catcmd == "cat" ]] && {
				tmp="${_fq1_sortmerna[$i]}"
			} || {
				commander::makecmd -a cmd1 -s '|' -c {COMMANDER[0]}<<- CMD
					$catcmd "${_fq1_sortmerna[$i]}" > $tmp
				CMD
			}

			commander::makecmd -a cmd2 -s '|' -c {COMMANDER[0]}<<- CMD
				sortmerna
				--ref "$sortmernaref"
				--reads "$tmp"
				--fastx
				--aligned "$tmpr"
				--other "$tmpo"
				-a $threads
			CMD
			commander::makecmd -a cmd3 -s '|' -c {COMMANDER[0]}<<- CMD
				pigz
				-p $threads
				-k
				-c
				"$tmpr".$e1 > "$or1"
			CMD
			commander::makecmd -a cmd3 -s '|' -c {COMMANDER[0]}<<- CMD
				pigz
				-p $threads
				-k
				-c
				"$tmpo".$e1 > "$o1"
			CMD
			_fq1_sortmerna[$i]="$o1"
		fi
	done

	if $skip; then
		commander::printcmd -a cmd1
		commander::printcmd -a cmd2
		commander::printcmd -a cmd3
	else
		commander::runcmd -v -b -t $instances -a cmd1
		commander::runcmd -v -b -t 1 -a cmd2
		commander::runcmd -v -b -t 1 -a cmd3
	fi

	return 0
}

preprocess::qcstats(){
	local tmp
	_cleanup::preprocess::qcstats(){
		rm -f "$tmp"
	}

	_usage() {
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[1]} usage:
			-S <hardskip> | true/false return
			-s <softskip> | true/false only print commands
			-i <qualdirs> | array of
			-o <outdir>   | path to
			-p <tmpdir>   | path to
			-1 <fastq1>   | array of
			-2 <fastq2>   | array of
		EOF
		return 1
	}

	local OPTIND arg mandatory skip=false outdir tmpdir
	declare -n _qualdirs_qcstats
	declare -n _fq1_qcstats _fq2_qcstats
	while getopts 'S:s:i:o:p:1:2:' arg; do
		case $arg in
			S) $OPTARG && return 0;;
			s) $OPTARG && skip=true;;
			i) ((++mandatory)); _qualdirs_qcstats=$OPTARG;;
			o) ((++mandatory)); outdir="$OPTARG"; mkdir -p "$outdir";;
			p) ((++mandatory)); tmpdir="$OPTARG"; mkdir -p "$tmpdir";;
			1) ((++mandatory)); _fq1_qcstats=$OPTARG;;
			2) _fq2_qcstats=$OPTARG;;
			*) _usage;;
		esac
	done
	[[ $mandatory -lt 4 ]] && _usage

	commander::printinfo "summarizing preprocessing stats"

	tmp="$(mktemp -p "$tmpdir" cleanup.XXXXXXXXXX.tsv)"
	local i o b e c multiplier qdir tool
	declare -a counts
	echo -e "sample\ttype\tcount" > "$outdir/preprocessing.barplot.tsv"
	for i in "${!_fq1_qcstats[@]}"; do
		helper::basename -f "${_fq1_qcstats[$i]}" -o b -e e
		o="$outdir/$b.stats"
		multiplier=1
		[[ "${_fq2_qcstats[$i]}" ]] && multiplier=2
		rm -f $o
		for qdir in "${_qualdirs_qcstats[@]}"; do
			tool=$(basename "$qdir")
			c=$(unzip -p "$qdir/${b}_fastqc.zip" "${b}_fastqc/fastqc_data.txt" | grep -m 1 -F Total | awk -v mult=$multiplier '{print $3*mult}')
			counts+=($c)
			echo -e "$b\t$tool reads\t$c" >> $o
			perl -sle 'print join"\t",("$sample ($all)","$tool reads",(100*$c/$all))' -- -all=${counts[$((i*${#_qualdirs_qcstats[@]}))]} -c=$c -sample=$b -tool=$tool
		done > "$tmp" # strange!!! if piped directly into tac - tac's awk implementation fails - not a shournal raceexception bug!
		tac "$tmp" | awk -F '\t' '{OFS="\t"; if(c){$NF=$NF-c} c=c+$NF; print}' | tac >> "$outdir/preprocessing.barplot.tsv"
	done

	declare -a cmd1
	commander::makecmd -a cmd1 -s ' ' -c {COMMANDER[0]}<<- 'CMD' {COMMANDER[1]}<<- CMD
		Rscript - <<< '
			suppressMessages(library("ggplot2"));
			suppressMessages(library("scales"));
			args <- commandArgs(TRUE);
			intsv <- args[1];
			outfile <- args[2];
			m <- read.table(intsv, header=T, sep="\t");
			l <- length(m$type)/length(unique(m$sample));
			l <- m$type[1:l];
			m$type = factor(m$type, levels=l);
			pdf(outfile);
			ggplot(m, aes(x = sample, y = count, fill = type)) +
				ggtitle("Preprocessing") + xlab("Sample") + ylab("Readcount in %") +
				theme_bw() + guides(fill=guide_legend(title=NULL)) +
				theme(axis.text.x = element_text(angle = 90, hjust = 1, vjust = 0.5, size = 8)) +
				geom_bar(position = "fill", stat = "identity") +
				scale_y_continuous(labels = percent_format());
			graphics.off();
		'
	CMD
		"$outdir/preprocessing.barplot.tsv"  "$outdir/preprocessing.barplot.pdf"
	CMD

	if $skip; then
		commander::printcmd -a cmd1
	else
		commander::runcmd -v -b -a cmd1
	fi

	return 0
}

#! /bin/sh

export LC_ALL=C

base=$(dirname $0)
. "${base}/md5.sh"

base64=tests/base64

test="${1#fate-}"
samples=$2
target_exec=$3
target_path=$4
command=$5
cmp=${6:-diff}
ref=${7:-"${base}/ref/fate/${test}"}
fuzz=${8:-1}
threads=${9:-1}
thread_type=${10:-frame+slice}
cpuflags=${11:-all}
cmp_shift=${12:-0}
cmp_target=${13:-0}
size_tolerance=${14:-0}

outdir="tests/data/fate"
outfile="${outdir}/${test}"
errfile="${outdir}/${test}.err"
cmpfile="${outdir}/${test}.diff"
repfile="${outdir}/${test}.rep"

# $1=value1, $2=value2, $3=threshold
# prints 0 if absolute difference between value1 and value2 is <= threshold
compare(){
    v=$(echo "scale=2; if ($1 >= $2) { $1 - $2 } else { $2 - $1 }" | bc)
    echo "if ($v <= $3) { 0 } else { 1 }" | bc
}

do_tiny_psnr(){
    psnr=$(tests/tiny_psnr "$1" "$2" 2 $cmp_shift 0)
    val=$(expr "$psnr" : ".*$3: *\([0-9.]*\)")
    size1=$(expr "$psnr" : '.*bytes: *\([0-9]*\)')
    size2=$(expr "$psnr" : '.*bytes:[ 0-9]*/ *\([0-9]*\)')
    val_cmp=$(compare $val $cmp_target $fuzz)
    size_cmp=$(compare $size1 $size2 $size_tolerance)
    if [ "$val_cmp" != 0 ] || [ "$size_cmp" != 0 ]; then
        echo "$psnr"
        return 1
    fi
}

oneoff(){
    do_tiny_psnr "$1" "$2" MAXDIFF
}

stddev(){
    do_tiny_psnr "$1" "$2" stddev
}

run(){
    test "${V:-0}" -gt 0 && echo "$target_exec" $target_path/"$@" >&3
    $target_exec $target_path/"$@"
}

avconv(){
    run avconv -nostats -threads $threads -thread_type $thread_type -cpuflags $cpuflags "$@"
}

framecrc(){
    avconv "$@" -f framecrc -
}

framemd5(){
    avconv "$@" -f framemd5 -
}

crc(){
    avconv "$@" -f crc -
}

md5(){
    avconv "$@" md5:
}

pcm(){
    avconv "$@" -vn -f s16le -
}

enc_dec_pcm(){
    out_fmt=$1
    pcm_fmt=$2
    shift 2
    encfile="${outdir}/${test}.${out_fmt}"
    cleanfiles=$encfile
    avconv -i $ref "$@" -f $out_fmt -y ${target_path}/${encfile} || return
    avconv -i ${target_path}/${encfile} -c:a pcm_${pcm_fmt} -f wav -
}

regtest(){
    t="${test#$2-}"
    ref=${base}/ref/$2/$t
    ${base}/${1}-regression.sh $t $2 $3 "$target_exec" "$target_path" "$threads" "$thread_type" "$cpuflags"
}

codectest(){
    regtest codec $1 tests/$1
}

lavftest(){
    regtest lavf lavf tests/vsynth1
}

lavfitest(){
    cleanfiles="tests/data/lavfi/${test#lavfi-}.nut"
    regtest lavfi lavfi tests/vsynth1
}

seektest(){
    t="${test#seek-}"
    ref=${base}/ref/seek/$t
    case $t in
        image_*) file="tests/data/images/${t#image_}/%02d.${t#image_}" ;;
        *)       file=$(echo $t | tr _ '?')
                 for d in acodec vsynth2 lavf; do
                     test -f tests/data/$d/$file && break
                 done
                 file=$(echo tests/data/$d/$file)
                 ;;
    esac
    run libavformat/seek-test $target_path/$file
}

mkdir -p "$outdir"

exec 3>&2
$command > "$outfile" 2>$errfile
err=$?

if [ $err -gt 128 ]; then
    sig=$(kill -l $err 2>/dev/null)
    test "${sig}" = "${sig%[!A-Za-z]*}" || unset sig
fi

if test -e "$ref"; then
    case $cmp in
        diff)   diff -u -w "$ref" "$outfile"            >$cmpfile ;;
        oneoff) oneoff     "$ref" "$outfile"            >$cmpfile ;;
        stddev) stddev     "$ref" "$outfile"            >$cmpfile ;;
        null)   cat               "$outfile"            >$cmpfile ;;
    esac
    cmperr=$?
    test $err = 0 && err=$cmperr
    test $err = 0 || cat $cmpfile
else
    echo "reference file '$ref' not found"
    err=1
fi

echo "${test}:${sig:-$err}:$($base64 <$cmpfile):$($base64 <$errfile)" >$repfile

test $err = 0 && rm -f $outfile $errfile $cmpfile $cleanfiles
exit $err

#! /bin/bash
. lib/env_func.bashrc

usage () {

  if [ "${QUEUE_TYPE}" == "SGE" ]; then
    echo "qsub -cwd  <<< '"
  elif [ "${QUEUE_TYPE}" == "LSF" ]; then
    echo "bsub -o logfile.txt <<< '"
  else
    echo_fail "unknonw QUEUE_TYPE: ${QUEUE_TYPE}"
  fi

  echo "/bin/bash $0 "
  echo "  -g file.hap "
  echo "  -l strainName.list (1-indexed[tab]individual name in the hap file)" 
  echo " [-n 20 (num. of dirs where large tmp files (output of chromopainter) are processed simultaneously, which can be increased in a larger disk: default=20) ]"
  echo ""
  echo " [-m pos2missingInd.txt (pos[tab]missing_individual_name]"
  echo " [-o strainName.list (1-indexed[tab]individual name in an order for output: default is as specified by -l) ]"
  echo " [-t 10 (num. of orderings and the reverse, default=10) ]"
  echo " [-s 1  (seed of random number generator: default=1) ]"

  echo "' "
  exit 1
}

################################################################################################################

#
# env
#
LIB_DIR=lib # created by setup.sh
LOG_DIR=log # created by setup.sh

EXE_PAINT=./${LIB_DIR}/chromopainter # also used in SH_PAINT_QSUB

PL_CHECK_LINE_LEN=./${LIB_DIR}/check_lineLen.pl
PL_MAKE_RECMAP=./${LIB_DIR}/makeuniformrecfile.pl
PL_ESTIMATE_Ne=./${LIB_DIR}/neaverage.pl

EXE_PREPARE_RECIPIENT_ORDER_HAPS=./${LIB_DIR}/randomize/rd
SH_PAINT_QSUB=./${LIB_DIR}/chromopainter_linkage_orderings_arrayjob.sh
PL_SITE_BY_SITE=./${LIB_DIR}/create_examine_site_by_site_matrices.pl
SH_DECOMPRESS_SORT_SPLIT_EACH_ORDERING=./${LIB_DIR}/decompress_sort_split_gz_arrayjob.sh
PL_MSORT_CLEAN_EACH_ORDERING=./${LIB_DIR}/msort_out_clean_each_ordering.pl
EXE_SORT=./${LIB_DIR}/sort 
EXE_PP=./${LIB_DIR}/postprocess/pp

R_MAIN1=./${LIB_DIR}/visualization1.R
R_LIB_HEATMAP=./${LIB_DIR}/plotHeatmap.R

R_MAIN2=./${LIB_DIR}/visualization2.R
SH_R_MAIN2=./${LIB_DIR}/visualization2_arrayjob.sh

R_CHECK_MISSING_STAT=./${LIB_DIR}/check_missingCnt_distStat.R


# to check existence below
arr_executable_files=(
  $EXE_PAINT
  $PL_CHECK_LINE_LEN
  $PL_MAKE_RECMAP
  $PL_ESTIMATE_Ne
  $EXE_PREPARE_RECIPIENT_ORDER_HAPS
  $EXE_PAINT
  $PL_SITE_BY_SITE
  $SH_DECOMPRESS_SORT_SPLIT_EACH_ORDERING
  $PL_MSORT_CLEAN_EACH_ORDERING
  $EXE_SORT
  $EXE_PP
)

arr_R_files=(
  $R_MAIN1
  $R_MAIN2
  $R_LIB_HEATMAP
  $R_CHECK_MISSING_STAT
)

#
# constant
#
NUM_EM=30 # 0-indexed. 10 is sometimes not enough for convergence

#
# rule
#
GZ_SORT_COPYPROB_EACH_DIR=copyprobsperlocus.cat.sort.gz

#
# vars
#
OUT_DIR=""


################################################################################################################

#
# func 
#   used only in this script
#   other functions are defined in lib/env_func.bashrc
#

move_log_files() {
  declare -a arr_logs
  arr_logs=`find . -maxdepth 1 -name $1\*$2\* -print`
  #if ls $1*$2* &> /dev/null; then
  for each_log in ${arr_logs[@]}
  do
    if [ -f "${each_log}" ]; then
      /bin/mv ${each_log} ${LOG_DIR}/ 
      echo "log file ${each_log} was moved to ${LOG_DIR}/"
    fi
  done
}

returnQSUB_CMD() {
  QSUB_CMD=""
  if [ "${QUEUE_TYPE}" == "SGE" -o "${QUEUE_TYPE}" == "UGE" ]; then
    QSUB_CMD="${QSUB_COMMON} -o $1.log -N $1"
  elif [ "${QUEUE_TYPE}" == "LSF" ]; then
    QSUB_CMD="${QSUB_COMMON} -o $1.log -J $1"
  fi
  
  if test "$2" = "" ; then
    QSUB_CMD=${QSUB_CMD}
  else
    if [ "${QUEUE_TYPE}" == "SGE" -o "${QUEUE_TYPE}" == "UGE" ]; then
      QSUB_CMD="${QSUB_CMD} -t $2:$3"
    elif [ "${QUEUE_TYPE}" == "LSF" ]; then
      QSUB_CMD="${QSUB_CMD}[$2-$3]"
    fi
  fi
  echo ${QSUB_CMD}
}

submit_calcAveDist_ordering() {
  CMD=`returnQSUB_CMD ${STAMP}`
  CMD=${CMD}" <<< '"
  CMD=${CMD}" perl ${PL_SITE_BY_SITE}"
  CMD=${CMD}" -g ${PHASEFILE} "
  CMD=${CMD}" -d ${ORDER_DIR_LIST} "
  CMD=${CMD}" -l ${ORDER_STRAIN_LIST} "
  #if [ "${CONTRAST_MAX}" -gt 0 ]; then
  #  CMD=${CMD}" -c ${CONTRAST_MAX} " 
  #fi
  CMD=${CMD}" -s ${HAP_LIST_OUTDISP} "
  #CMD=${CMD}" -n ${i_ordering}"
  CMD=${CMD}" -n $1"
  if [ "${MISSING_POS_IND_FILE}" != "" ]; then
    CMD=${CMD}" -m ${MISSING_POS_IND_FILE}"
  fi
  if [ "${CONSTRAINT_FILE}" != "" ]; then
    CMD=${CMD}" -c ${CONSTRAINT_FILE}"
  fi
  CMD=${CMD}"'"

  echo ${CMD}
  eval ${CMD}
  if [ $? -ne 0 ]; then 
    echo_fail "Execution error: ${CMD} (step${STEP})"
  fi
}

wait_until_finish() {
  sleep 10
  while :
  do
    QSTAT_CMD=qstat
    END_CHECK=`${QSTAT_CMD} | grep -e $1 -e 'not ready yet' | wc -l`
    if [ "${END_CHECK}" -eq 0 ]; then
      sleep 10
      break
    fi
    sleep 10
  done
}

submit_msort_for_decompressed_dirs() {
  i_dir=0
  while [ "$i_dir" -lt ${#arr_dirs_being_decompressed[@]} ]; do
    date +%Y%m%d_%T
    
    CMD=`returnQSUB_CMD ${STAMP}`
    CMD=${CMD}" <<< '"
    CMD=${CMD}" perl ${PL_MSORT_CLEAN_EACH_ORDERING} -d ${arr_dirs_being_decompressed[$i_dir]} -g ${PHASEFILE} "
    CMD=${CMD}" -t 1 " # unordered
    CMD=${CMD}"'"
    #
    # msort
    #   25min per an ordering for N=200, P=222717 (with | gzip), temporary 60GB
    #   11min per an ordering for N=200, P=222717 (without | gzip)
    #
    # the script checks whether the output file (copyprobsperlocus.cat.sort.gz) is incomplete or not
    #   and re-execute it until the complete output file is obtained
    #
    echo ${CMD}
    eval ${CMD}
    if [ $? -ne 0 ]; then 
      echo_fail "Execution error: ${CMD} (step${STEP}) "
    fi
    #
    # update the array by removing the submitted dir
    #
    unset arr_dirs_being_decompressed[$i_dir]
    arr_dirs_being_decompressed=(${arr_dirs_being_decompressed[@]})
  done
  # this loop automatically ends after submitting msort jobs for the decompressed dirs
}

get_stamp() {
  DATE_N=`date +%N`
  TIME_DIGIT=`echo "$(date +%H%S)$(printf '%02d' $(expr $DATE_N / 10000000))"` # hour(2)sec(2)milisec(2)
  #if ls "s$1_${TIME_DIGIT}"* &> /dev/null; then
  while ls "s$1_${TIME_DIGIT}"* &> /dev/null
  do
    sleep 1
    DATE_N=`date +%N`
    TIME_DIGIT=`echo "$(date +%H%S)$(printf '%02d' $(expr $DATE_N / 10000000))"` # hour(2)sec(2)milisec(2)
  done
  #fi
  STAMP="s$1_${TIME_DIGIT}"
}

disp_punctuate() {
  echo "*************** STEP$1, log=$2.log ****************************** "
  date +%Y%m%d_%T
}

################################################################################################################

#
# args
#
SEED=1
TYPE_NUM_ORDERING=10
VERBOSE=FALSE
CONTRAST_MAX=-9999
MAX_PARALLEL_DECOMPRESS=20
MISSING_POS_IND_FILE=""
CONSTRAINT_FILE=""
while getopts g:t:s:l:o:n:m:c:v OPTION
do
  case $OPTION in
    g)  if [ ! -z "${OPTARG}" ];then PHASEFILE=${OPTARG} ;else usage ;fi
        ;;

    l)  if [ ! -z "${OPTARG}" ];then 
          HAP_LIST=${OPTARG}
          HAP_LIST_OUTDISP=${OPTARG}
        else 
          usage
        fi
        ;;

    o)  if [ ! -z "${OPTARG}" ];then HAP_LIST_OUTDISP=${OPTARG} ;else usage ;fi
        ;;
    t)  if [ ! -z "${OPTARG}" ];then TYPE_NUM_ORDERING=${OPTARG} ;else usage ;fi
        ;;
    s)  if [ ! -z "${OPTARG}" ];then SEED=${OPTARG} ;else usage ;fi
        ;;

    n)  if [ ! -z "${OPTARG}" ];then MAX_PARALLEL_DECOMPRESS=${OPTARG} ;else usage ;fi
        ;;
    m)  if [ ! -z "${OPTARG}" ];then MISSING_POS_IND_FILE=${OPTARG} ;else usage ;fi
        ;;
    c)  if [ ! -z "${OPTARG}" ];then CONSTRAINT_FILE=${OPTARG} ;else usage ;fi
        ;;

    v)  VERBOSE=TRUE
        ;;
    \?) usage ;;
  esac
done

#
# output files (for error check)
#
OUTF_SITE_DISTSCORE=site_distScore.txt
OUTF_SITE_STATS=results_siteStats.txt.gz

OUTF_SUMMARY_POS=site_minus_average.matrix.summary.pos.txt
OUTF_SUMMARY_TXT=sum_site_minus_average.summary.txt.gz
OUTF_SUMMARY_RANGE=sum_site_minus_average.summary.range.txt

PNG_HIST=results_siteStats_hist.png
PNG_ALONG_SEQ=results_siteStats_along_seq.png

#
# check env
#
if [ "${QUEUE_TYPE}" == "SGE" -o "${QUEUE_TYPE}" == "UGE" ]; then
  CHECK=`which qsub`
  if [ "${CHECK}" == "" ]; then
    echo_fail "Error: qsub is not available"
  fi
elif [ "${QUEUE_TYPE}" == "LSF" ]; then
  CHECK=`which bsub`
  if [ "${CHECK}" == "" ]; then
    echo_fail "Error: bsub is not available"
  fi
fi

for aa in ${arr_executable_files[@]}
do
  if [ ! -x "${aa}" ]; then
    echo_fail "Environment error: ${aa} doesn't exist or is not executable.  Please execute setup.sh first."
  fi
done

for aa in ${arr_R_files[@]}
do
  if [ ! -f "${aa}" ]; then
    echo_fail "Environment error: ${aa} doesn't exist"
  fi
done

#
# check args
#
if [ $# -lt 2 ] ; then
  usage
fi

if [ ! -f "${PHASEFILE}" ]; then
  echo_fail "Error: ${PHASEFILE} doesn't exist"
fi

WC_UQ_HAP_LEN=`${PL_CHECK_LINE_LEN} -f ${PHASEFILE} | tail -n +5 | uniq | wc -l`
if [ "${WC_UQ_HAP_LEN}" -gt 1 ]; then
  echo_fail "Error: haplotype sequences with different length are found in ${PHASEFILE}"
fi

NUM_IND=`head -2 ${PHASEFILE} | tail -1`


if [ ! -f "${HAP_LIST}" ]; then
  echo_fail "Error: ${HAP_LIST} doesn't exist"
fi

if [ "${MISSING_POS_IND_FILE}" != "" ]; then
  if [ ! -f "${MISSING_POS_IND_FILE}" ]; then
    echo_fail "Error: ${MISSING_POS_IND_FILE} doesn't exist"
  fi

  MAX_MISSING=`awk '{print $1}' ${MISSING_POS_IND_FILE} | uniq -c |sort -n -r |head -1 | awk '{print $1}'`
  if [ "${MAX_MISSING}" -ge "${NUM_IND}" ]; then
    echo_fail "Error: too many missng data, with maximum=${MAX_MISSING} "
  fi
fi

#
# check ${HAP_LIST}
#
CHECK_CR=`od -c "${HAP_LIST}" | grep "\r"`
if [ "${CHECK_CR}" != "" ]; then
  perl -i -pe 's/\r//g' ${HAP_LIST}
fi

WC_HAP_LIST=`wc -l ${HAP_LIST} | awk '{print $1}'`
if [ "${WC_HAP_LIST}" -ne "${NUM_IND}" ]; then
  echo_fail "Error: The number of rows of ${HAP_LIST} must be ${NUM_IND}, but ${WC_HAP_LIST}"
fi

if [ ! -f "${HAP_LIST}.id" ]; then
  seq 1 ${NUM_IND} | sort > ${HAP_LIST}.id.correct
  awk '{print $1}' ${HAP_LIST} | sort > ${HAP_LIST}.id
  DIFF=`diff ${HAP_LIST}.id.correct ${HAP_LIST}.id`
  if [ "${DIFF}" != "" ]; then
    echo_fail "Error: 1st column of ${HAP_LIST} is wrong: ${DIFF}"
  fi
fi

# 
# check ${HAP_LIST_OUTDISP}
#
if [ "${HAP_LIST}" != "${HAP_LIST_OUTDISP}" ]; then
  CHECK_CR=`od -c "${HAP_LIST_OUTDISP}" | grep "\r"`
  if [ "${CHECK_CR}" != "" ]; then
    perl -i -pe 's/\r//g' ${HAP_LIST_OUTDISP}
  fi

  WC_HAP_LISTDISP=`wc -l ${HAP_LIST_OUTDISP} | awk '{print $1}'`
  if [ "${WC_HAP_LISTDISP}" -ne "${NUM_IND}" ]; then
    echo_fail "Error: The number of rows of ${HAP_LIST_OUTDISP} must be ${NUM_IND}, but ${WC_HAP_LISTDISP}"
  fi

  if [ ! -s "${HAP_LIST_OUTDISP}.names" ]; then
    awk '{print $2}' ${HAP_LIST}         | sort > ${HAP_LIST}.names
    awk '{print $2}' ${HAP_LIST_OUTDISP} | sort > ${HAP_LIST_OUTDISP}.names
    DIFF=`diff ${HAP_LIST}.names ${HAP_LIST_OUTDISP}.names`
    if [ "${DIFF}" != "" ]; then
      echo_fail "Error: difference of names between ${HAP_LIST} and ${HAP_LIST_OUTDISP}: ${DIFF}"
    fi
  fi
fi

#
# check ${MISSING_POS_IND_FILE}
#
if [ "${MISSING_POS_IND_FILE}" != "" ]; then
  CHECK_CR=`od -c "${MISSING_POS_IND_FILE}" | grep "\r"`
  if [ "${CHECK_CR}" != "" ]; then
    perl -i -pe 's/\r//g' ${MISSING_POS_IND_FILE}
  fi

  if [ ! -s "${MISSING_POS_IND_FILE}.names" ]; then
    awk '{print $2}' ${MISSING_POS_IND_FILE} | sort -u > ${MISSING_POS_IND_FILE}.names

    if [ ! -s "${HAP_LIST}.names" ]; then
      awk '{print $2}' ${HAP_LIST}  | sort > ${HAP_LIST}.names
    fi

    DIFF=`comm -23 ${MISSING_POS_IND_FILE}.names ${HAP_LIST}.names`
    if [ "${DIFF}" != "" ]; then
      echo_fail "Error: some strain names in ${MISSING_POS_IND_FILE} are not found in ${HAP_LIST}"
    fi
  fi
fi

#
# prepare
#
OUT_PREFIX_BASE=`echo ${PHASEFILE} | perl -pe 's/^.*\///g' | perl -pe "s/\.hap//g"`

TGZ_ORDER_PAINTINGS=${OUT_PREFIX_BASE}_orderedS${SEED}_both_paintings.tgz

#declare -a arr_STAMP

cwd=`dirname $0` 
cd $cwd

################################################################################################################

#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
# create (uniform) recombination map
# estimation of Ne
#   according to http://paintmychromosomes.com/
#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
STEP=1

get_stamp ${STEP}
#arr_STAMP=("${arr_STAMP[@]}" "${STAMP}")
disp_punctuate ${STEP} ${STAMP}

NUM_IND=`head -2 ${PHASEFILE} | tail -1 | perl -pe 's/\n//g'`

OUT_DIR_linked1_est=${OUT_PREFIX_BASE}_linked_out1_respartsEM
if [ ! -d "${OUT_DIR_linked1_est}" ]; then
  mkdir ${OUT_DIR_linked1_est}
fi

#
# (uniform) recombination map
#
RECOMB_FNANE=${OUT_PREFIX_BASE}_linked.rec
if [ -s "${RECOMB_FNANE}" ]; then
  echo "${RECOMB_FNANE} already exists.  Skipped."
else
  perl ${PL_MAKE_RECMAP} ${PHASEFILE} ${RECOMB_FNANE}
fi

#
# EM inference of Ne (recombination rate) on a subset of data 
#
globalparams=""
N_e=""
N_e_FNAME=${OUT_PREFIX_BASE}_linked.neest

if [ -s "${N_e_FNAME}" ]; then
  echo "${N_e_FNAME} already exists.  Skipped."
else

  #
  # check format of hap file 
  #
  CMD="${EXE_PAINT} -a 1 1 -j -g $PHASEFILE -r $RECOMB_FNANE -o ${OUT_DIR_linked1_est}/formatcheck > /dev/null 2>&1 &"
  echo ${CMD}
  eval ${CMD}
  PID=$!
  if [ $? -ne 0 ]; then 
    echo_fail "Error: format of $PHASEFILE is wrong. "
  else
    kill ${PID}
    wait ${PID} > /dev/null 2>&1
    if ls ${OUT_DIR_linked1_est}/formatcheck* &> /dev/null; then
      /bin/rm -f ${OUT_DIR_linked1_est}/formatcheck*
    fi
  fi

  #
  # start
  #
  INCREMENT=1
  if [ "${NUM_IND}" -gt 30 ]; then
    INCREMENT=`expr $NUM_IND / 30`
    let INCREMENT=${INCREMENT}+1
  fi

  for ind in `seq 1 ${INCREMENT} ${NUM_IND}`
  do
    out_prefix_ind=${OUT_PREFIX_BASE}_${ind}

    CMD=`returnQSUB_CMD ${STAMP}`
    CMD=${CMD}" <<< '"
    CMD=${CMD}"${EXE_PAINT} -i ${NUM_EM} -in -n 1 -a $ind $ind -j -g $PHASEFILE -r $RECOMB_FNANE -o ${OUT_DIR_linked1_est}/${out_prefix_ind}"
    CMD=${CMD}"'"
    echo ${CMD}
    eval ${CMD}
    if [ $? -ne 0 ]; then 
      echo_fail "Execution error: ${CMD} (step${STEP}_1) "
    fi
  done

  OUT_DIR=${OUT_DIR_linked1_est}
  wait_until_finish "${STAMP}"

  # remove unnecessary files
  ls ${OUT_DIR_linked1_est}/${OUT_PREFIX_BASE}*.out | grep -v EMprobs | xargs rm
  ls ${OUT_DIR_linked1_est}/${OUT_PREFIX_BASE}*.copyprobsperlocus.out.gz | xargs rm

  # summarize *.EMprobs.out files and estimate Ne
  let WC_CONVERGED=${NUM_EM}+2
  for aa in `wc -l ${OUT_DIR_linked1_est}/${OUT_PREFIX_BASE}*.EMprobs.out | grep -v " ${WC_CONVERGED} " | grep -v total | awk '{print $2}'`
  do
    if [ -f ${aa} ]; then
      /bin/mv ${aa} ${aa}.notconverged
    fi
  done
  CMD="${PL_ESTIMATE_Ne} -o ${N_e_FNAME} ${OUT_DIR_linked1_est}/${OUT_PREFIX_BASE}*.EMprobs.out "
  echo "executing ${PL_ESTIMATE_Ne} -o ${N_e_FNAME} ${OUT_DIR_linked1_est}/${OUT_PREFIX_BASE}*.EMprobs.out ... "
  #echo ${CMD}
  eval ${CMD}
  if [ $? -ne 0 ]; then 
    echo_fail "Execution error: ${CMD} (step${STEP}_2) "
  fi
fi


globalparams=`cat $N_e_FNAME` # $N_e_FNAME contains the commands to tell ChromoPainter about both Ne and global mutation rate, e.g. "-n 10000 -M 0.01".
N_e=`cat $N_e_FNAME | awk '{print $2}' `

if [ "${globalparams}" == "" ]; then 
  echo_fail "Error (step${STEP}): global params infered by EM are empty"
fi

move_log_files "${STAMP}"

#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
# prepare ordered *.hap files 
#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
STEP=2

get_stamp ${STEP}
#arr_STAMP=("${arr_STAMP[@]}" "${STAMP}")
disp_punctuate ${STEP} ${STAMP}

ORDER_HAP_LIST=${OUT_PREFIX_BASE}_orderedS${SEED}_hap.list
ORDER_DIR_LIST=${OUT_PREFIX_BASE}_orderedS${SEED}_rnd_1_${TYPE_NUM_ORDERING}_dirs.list
ORDER_STRAIN_LIST=${OUT_PREFIX_BASE}_orderedS${SEED}_rnd_1_${TYPE_NUM_ORDERING}_dirs_strainOrder.list

#
# check (in case of re-execution)
#
DONE_ALL_GZ_SORT_COPYPROB_EACH_DIR=0
if [ -s "${ORDER_DIR_LIST}" ]; then
  DONE_ALL_GZ_SORT_COPYPROB_EACH_DIR=1
  while read EACH_DIR
  do
    if [ ! -s "${EACH_DIR}/${GZ_SORT_COPYPROB_EACH_DIR}" ]; then
      DONE_ALL_GZ_SORT_COPYPROB_EACH_DIR=0
    else
      CHECK_GZ_SORT_COPYPROB_EACH_DIR=`gzip -dc ${EACH_DIR}/${GZ_SORT_COPYPROB_EACH_DIR} | head | wc -l`
      if [ ${CHECK_GZ_SORT_COPYPROB_EACH_DIR} -eq 0 ]; then
        DONE_ALL_GZ_SORT_COPYPROB_EACH_DIR=0
        
        /bin/rm -f ${EACH_DIR}/${GZ_SORT_COPYPROB_EACH_DIR}
        echo "incomplete ${EACH_DIR}/${GZ_SORT_COPYPROB_EACH_DIR} was removed"
      fi
    fi
  done < ${ORDER_DIR_LIST}
fi

if [ "${DONE_ALL_GZ_SORT_COPYPROB_EACH_DIR}" -eq 0 ]; then
  
  i_forward_reverse=1
  while [ "${i_forward_reverse}" -le "${TYPE_NUM_ORDERING}"  ]
  do
    # always recreate (because they are removed in the step${STEP})
    CMD=`returnQSUB_CMD ${STAMP}`
    CMD=${CMD}" <<< '"
    CMD=${CMD}"${EXE_PREPARE_RECIPIENT_ORDER_HAPS} "
    CMD=${CMD}" -h ${PHASEFILE}"
    CMD=${CMD}" -p ${OUT_PREFIX_BASE}"
    CMD=${CMD}" -l ${HAP_LIST}"
    CMD=${CMD}" -o ${HAP_LIST_OUTDISP}"
    CMD=${CMD}" -t ${i_forward_reverse}"
    CMD=${CMD}" -s ${SEED}" 
    CMD=${CMD}"'"
    
    echo ${CMD}
    eval ${CMD}
    if [ $? -ne 0 ]; then 
      echo_fail "Execution error: ${CMD} (step${STEP}) "
    fi

    let i_forward_reverse=${i_forward_reverse}+1
  done

  wait_until_finish "${STAMP}"


  # ${ORDER_HAP_LIST}
  i_forward_reverse=1
  while [ "${i_forward_reverse}" -le "${TYPE_NUM_ORDERING}"  ]
  do
    EACH_DIR_PREFIX=$(printf %s_orderedS%s_rnd%02d ${OUT_PREFIX_BASE} ${SEED} ${i_forward_reverse})
    CMD="ls ${EACH_DIR_PREFIX}_*/*.hap "
    if [ "${i_forward_reverse}" -eq 1 ]; then
      CMD=${CMD}" >  ${ORDER_HAP_LIST}"
    else
      CMD=${CMD}" >> ${ORDER_HAP_LIST}"
    fi
    #echo ${CMD}
    eval ${CMD}
    if [ $? -ne 0 ]; then 
      echo_fail "Error: ${CMD}  "
    fi
    let i_forward_reverse=${i_forward_reverse}+1
  done
  echo "${ORDER_HAP_LIST} was created"

fi


if [ ! -s "${ORDER_DIR_LIST}" ]; then
  CMD="find ./ -maxdepth 1 -type d -name ${OUT_PREFIX_BASE}_orderedS${SEED}_rnd\* | grep -v results | perl -pe 's/^\.\///g' | sort > ${ORDER_DIR_LIST}"
  #echo ${CMD}
  eval ${CMD}
  if [ $? -ne 0 ]; then 
    echo_fail "Error: ${ORDER_DIR_LIST} "
  fi
  echo "${ORDER_DIR_LIST} was created"
fi

if [ ! -s "${ORDER_STRAIN_LIST}" ]; then
  CMD="cat ${ORDER_DIR_LIST} | perl -pe 's/\n/.strainOrder\n/g' > ${ORDER_STRAIN_LIST}"
  #echo ${CMD}
  eval ${CMD}
  if [ $? -ne 0 ]; then 
    echo_fail "Error: ${ORDER_STRAIN_LIST} "
  fi
  echo "${ORDER_STRAIN_LIST} was created"
fi

move_log_files "${STAMP}"

#
# tmp files created at the begining
#
if [ -f "${HAP_LIST}.id.correct" ]; then
  /bin/rm -f ${HAP_LIST}.id.correct
fi

if [ -f "${HAP_LIST}.id" ]; then
  /bin/rm -f ${HAP_LIST}.id
fi

if [ -f "${HAP_LIST}.names" ]; then
  /bin/rm -f ${HAP_LIST}.names
fi

if [ -f "${HAP_LIST_OUTDISP}.names" ]; then
  /bin/rm -f ${HAP_LIST_OUTDISP}.names
fi



#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
# execute chromopainter on the ordering-based condition
#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
STEP=3

get_stamp ${STEP}
#arr_STAMP=("${arr_STAMP[@]}" "${STAMP}")
disp_punctuate ${STEP} ${STAMP}

TARGET_HAP_FNANE="target_hap.list"

#NUM_HAP=`head -2 ${PHASEFILE} | tail -1`
#NUM_SITE=`head -3 ${PHASEFILE} | tail -1`
#let NUM_ROW_COPYPROB=${NUM_SITE}+2

while read EACH_DIR
do
  #
  # prepare $TARGET_HAP_LIST, $NUM_TARGET_HAP
  #
  NUM_TARGET_HAP=0
  TARGET_HAP_LIST="${EACH_DIR}/${TARGET_HAP_FNANE}"
  cat /dev/null > ${TARGET_HAP_LIST}
  echo "preparing ${TARGET_HAP_LIST} ... "

  CHECK_GZ_SORT_COPYPROB_EACH_DIR=0
  if [ -f "${EACH_DIR}/${GZ_SORT_COPYPROB_EACH_DIR}" ]; then
    CHECK_GZ_SORT_COPYPROB_EACH_DIR=`gzip -dc ${EACH_DIR}/${GZ_SORT_COPYPROB_EACH_DIR} | head | wc -l`
  fi
  # skip this ordered directory if there is ${GZ_SORT_COPYPROB_EACH_DIR} created by the next step
  if [ ${CHECK_GZ_SORT_COPYPROB_EACH_DIR} -gt 0 ]; then
    echo "  painting in ${EACH_DIR} is skipped because there is already ${GZ_SORT_COPYPROB_EACH_DIR}"
  else
    for EACH_HAP in `grep ${EACH_DIR} ${ORDER_HAP_LIST}`
    do
      EACH_COPYPROB_GZ=`echo ${EACH_HAP} | perl -pe 's/\.hap$/.copyprobsperlocus.out.gz/g'`

      target_flag=0
      if [ ! -s "${EACH_COPYPROB_GZ}" ]; then
        target_flag=1
      else
        CHECK_HEAD=`gzip -dc ${EACH_COPYPROB_GZ} | head | wc -l`
        if [ $? -ne 0 -o "${CHECK_HEAD}" -eq 0 ]; then
          target_flag=1
          
          /bin/rm -f ${EACH_COPYPROB_GZ}
          echo "incomplete ${EACH_COPYPROB_GZ} was removed"
        fi
      fi
      # otherwise, execute painting of unfinished hap files in this ordered directory 
      if [ "${target_flag}" -eq 1 ]; then
        echo ${EACH_HAP} >> ${TARGET_HAP_LIST}
        let NUM_TARGET_HAP=${NUM_TARGET_HAP}+1
      else
        echo "${EACH_COPYPROB_GZ} already exists and is not empty.  Skipped."
      fi
    done
  fi

  #
  # execute paining of the target hap files
  #
  if [ "${NUM_TARGET_HAP}" -eq 0 ]; then
    echo "${EACH_DIR} was skipped because there is no hap file to be painted."
  else
    ARRAY_S=1
    ARRAY_E=${NUM_TARGET_HAP}
    
    CMD=`returnQSUB_CMD ${STAMP} ${ARRAY_S} ${ARRAY_E}`
    #CMD=${CMD}" -t 1:${NUM_TARGET_HAP} "
    CMD=${CMD}" ${SH_PAINT_QSUB}"
    CMD=${CMD}"  -r ${RECOMB_FNANE}"
    CMD=${CMD}"  -n ${N_e_FNAME}"
    CMD=${CMD}"  -l ${TARGET_HAP_LIST}"

    echo ${CMD}
    QSUB_MSG=`${CMD}`
    if [ $? -ne 0 ]; then 
      echo_fail "Execution error: ${CMD} (step${STEP}) "
    fi
    #QSUB_ID=`echo ${QSUB_MSG} | perl -pe 's/ \(.*$//g' | perl -pe 's/^.* //g' | perl -pe 's/\..*$//g'`
  fi

done < ${ORDER_DIR_LIST}

wait_until_finish "${STAMP}"

# check whether there is any incomplete .copyprobsperlocus.out.gz
echo "checking output (.copyprobsperlocus.out.gz) files of the step${STEP} ..."

i_failed=0
while read EACH_DIR
do
  echo "${EACH_DIR}"
  i_HAP=0
  TARGET_HAP_LIST="${EACH_DIR}/${TARGET_HAP_FNANE}"
  while read EACH_HAP
  do
    let i_HAP=${i_HAP}+1
    EACH_COPYPROB_GZ=`echo ${EACH_HAP} | perl -pe 's/\.hap/.copyprobsperlocus.out.gz/g'`
    
    if [ -f "${EACH_COPYPROB_GZ}" ]; then
      CHECK_HEAD=`gzip -dc ${EACH_COPYPROB_GZ} | head | wc -l`
      if [ $? -ne 0 -o "${CHECK_HEAD}" -eq 0 ]; then
        echo "painting of ${EACH_HAP} failed, because ${EACH_COPYPROB_GZ} is an incomplete file"
        let i_failed=${i_failed}+1
        
        /bin/rm -f ${EACH_COPYPROB_GZ}
        echo "incomplete ${EACH_COPYPROB_GZ} was removed"
      fi
    fi

  done < "${TARGET_HAP_LIST}"
done < ${ORDER_DIR_LIST}

if [ "${i_failed}" -gt 0 ]; then
  echo_fail "There are ${i_failed} failed jobs.  Please execute this program again (already finished jobs will be skipped)."
fi

move_log_files "${STAMP}"

################################################################################################################

#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
# postprocessing 1
#   for each ordering,
#   merge and sort .copyprobsperlocus.out > ${GZ_SORT_COPYPROB_EACH_DIR}
#
#     it can require a large temporary disk in each ordering
#     (e.g., N=500, SNP=100,000 => about 100GB per ordering
#            N=200, SNP=222,717 =>        60GB per ordering)
#
#     disk size is the limiting factor of the number of parallelization
#     (default=5, can be changed by -n option)
#
#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
STEP=4

get_stamp ${STEP}
#arr_STAMP=("${arr_STAMP[@]}" "${STAMP}")
disp_punctuate ${STEP} ${STAMP}

TARGET_GZ_FNANE="target_gz.list"

declare -a arr_dirs_being_decompressed

while read EACH_DIR
do
  #
  # prepare $TARGET_HAP_LIST, $NUM_TARGET_HAP
  #
  TARGET_GZ_LIST="${EACH_DIR}/${TARGET_GZ_FNANE}"
  cat /dev/null > "${TARGET_GZ_LIST}"
  echo "preparing ${TARGET_GZ_LIST} ... "

  if ls ${EACH_DIR}/*copyprobsperlocus.out.gz &> /dev/null; then
    CMD="ls ${EACH_DIR}/*copyprobsperlocus.out.gz > ${TARGET_GZ_LIST}"
    #echo ${CMD}
    eval ${CMD}
    if [ $? -ne 0 ]; then 
      echo_fail "Execution error: ${CMD} (step${STEP}) "
    fi
  fi

  NUM_TARGET_GZ=`wc -l ${TARGET_GZ_LIST} | awk '{print $1}'`

  CHECK_GZ_SORT_COPYPROB_EACH_DIR=0
  if [ -f "${EACH_DIR}/${GZ_SORT_COPYPROB_EACH_DIR}" ]; then
    CHECK_GZ_SORT_COPYPROB_EACH_DIR=`gzip -dc ${EACH_DIR}/${GZ_SORT_COPYPROB_EACH_DIR} | head | wc -l`
  fi
  # skip this ordered directory if there is already ${GZ_SORT_COPYPROB_EACH_DIR} 
  if [ ${CHECK_GZ_SORT_COPYPROB_EACH_DIR} -gt 0 ]; then
    echo "  msort in${EACH_DIR} is skipped because there is already ${GZ_SORT_COPYPROB_EACH_DIR}"
  else
    #
    # decompress each .copyprobsperlocus.out.gz file,
    # sort it by position (ascending), 
    # split every 50000 line
    # cat and save it as copyprobsperlocus.out
    #
    #   in order to use "sort -m" which is much faster and can handle large data
    #
    #   the number of parallelization is controlled by ${MAX_PARALLEL_DECOMPRESS} to deal with limit of disk space
    #
    ARRAY_S=1
    ARRAY_E=${NUM_TARGET_GZ}

    if [ "${NUM_TARGET_GZ}" -gt 0 ]; then
      CMD=`returnQSUB_CMD ${STAMP} ${ARRAY_S} ${ARRAY_E}`
      #CMD=${CMD}" -t 1:${NUM_TARGET_GZ} "
      CMD=${CMD}" ${SH_DECOMPRESS_SORT_SPLIT_EACH_ORDERING}"
      CMD=${CMD}"  -l ${TARGET_GZ_LIST}"

      echo ${CMD}
      QSUB_MSG=`${CMD}`
      if [ $? -ne 0 ]; then 
        echo_fail "Execution error: ${CMD} (step${STEP}) "
      fi
      arr_dirs_being_decompressed=("${arr_dirs_being_decompressed[@]}" "${EACH_DIR}")
    else
      echo "${SH_DECOMPRESS_SORT_SPLIT_EACH_ORDERING} was not executed for ${EACH_DIR} (no *.gz file) "
    fi

    while :
    do
      #
      # when the number of dirs to be processed > ${MAX_PARALLEL_DECOMPRESS}
      #
      if [ "${#arr_dirs_being_decompressed[@]}" -ge "${MAX_PARALLEL_DECOMPRESS}" ]; then
        #
        # wait decompression (for dirs submitted above)
        #
        wait_until_finish "${STAMP}"

        #
        # then submit msort for each decompressed dir
        #
        submit_msort_for_decompressed_dirs "${STAMP}"
        #
        # wait until the submitted msort jobs are finished
        #
        wait_until_finish "${STAMP}"
      else 
      #
      # otherwise, proceed to qsub of the next ordering
      #
        break
      fi

      sleep 10
    done

  fi
done < ${ORDER_DIR_LIST}

#
# wait decompression (for dirs submitted above)
#   if ${MAX_PARALLEL_DECOMPRESS} >= 2*NUM_ORDERING, 
#   the program waits decompression only at this point
#   (decompresss all dirs at the same time)
#
wait_until_finish "${STAMP}"

#
# then submit msort for each decompressed dir
#
submit_msort_for_decompressed_dirs "${STAMP}"
#
# wait until the submitted msort jobs are finished
#
wait_until_finish "${STAMP}"

#
# check ${GZ_SORT_COPYPROB_EACH_DIR} in each dir
#
sleep 1
while read EACH_DIR
do
  if [ ! -s "${EACH_DIR}/${GZ_SORT_COPYPROB_EACH_DIR}" ]; then
    echo_fail "Error: ${EACH_DIR}/${GZ_SORT_COPYPROB_EACH_DIR} doesn't exist or empty"
  else
    CHECK_HEAD=`gzip -dc ${EACH_DIR}/${GZ_SORT_COPYPROB_EACH_DIR} | head | wc -l`
    if [ $? -ne 0 -o "${CHECK_HEAD}" -eq 0 ]; then
      echo_fail "Error: ${EACH_DIR}/${GZ_SORT_COPYPROB_EACH_DIR} is an incomplete file"
    fi
  fi

  if ls ${EACH_DIR}/sort?????? &> /dev/null; then
    /bin/rm -f ${EACH_DIR}/sort??????
  fi
done < ${ORDER_DIR_LIST}

move_log_files "${STAMP}"


#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
# postprocessing 2 (l1,l2)
#   calculate average, and distance to the average for each ordering
#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
STEP=5

get_stamp ${STEP}
#arr_STAMP=("${arr_STAMP[@]}" "${STAMP}")
disp_punctuate ${STEP} ${STAMP}

i_submitted=0

i_ordering=1
while read EACH_DIR
do
  if [ ! -s "${EACH_DIR}/${OUTF_SITE_DISTSCORE}" ]; then # doesn't exist or empty
    submit_calcAveDist_ordering "${i_ordering}"
    let i_submitted=${i_submitted}+1
  else
    echo "step${STEP} of ${EACH_DIR} was skipped, because ${OUTF_SITE_DISTSCORE} already exists there";
  fi
  let i_ordering=${i_ordering}+1
done < ${ORDER_DIR_LIST}


if [ "${i_submitted}" -gt 0 ]; then

  wait_until_finish "${STAMP}"

  #
  # check the output file
  # 
  while read EACH_DIR
  do
    if [ ! -s "${EACH_DIR}/${OUTF_SITE_DISTSCORE}" ]; then
      echo_fail "Error (step${STEP}): ${EACH_DIR}/${OUTF_SITE_DISTSCORE} doesn't exist or empty"
    fi
  done < ${ORDER_DIR_LIST}
  
fi

move_log_files "${STAMP}"


#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
# postprocessing 3 (l3)
#   combine results of all orderings and produce final results
#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
STEP=6

arr_summary_type=(
  'top'
  'middle'
  'bottom'
)

get_stamp ${STEP}
#arr_STAMP=("${arr_STAMP[@]}" "${STAMP}")
disp_punctuate ${STEP} ${STAMP}

COMBINED_RES_DIR=`echo ${ORDER_DIR_LIST} | perl -pe 's/\.list/_results/g'`

SKIP_FLAG=0
if [ -s "${COMBINED_RES_DIR}/${OUTF_SITE_STATS}" ]; then
  if [ -s "${COMBINED_RES_DIR}/${OUTF_SUMMARY_POS}" ]; then
    if [ -s "${COMBINED_RES_DIR}/${OUTF_SUMMARY_TXT}" ]; then
      if [ -s "${COMBINED_RES_DIR}/${OUTF_SUMMARY_RANGE}" ]; then
        DIRS_OK_FLAG=1
        for type in ${arr_summary_type[@]}
        do
          if [ ! -d "${COMBINED_RES_DIR}/${type}" ]; then
            DIRS_OK_FLAG=0
          fi
        done

        if [ "${DIRS_OK_FLAG}" -eq 1 ]; then
          SKIP_FLAG=1
        fi
      fi
    fi
  fi
fi

if [ "${SKIP_FLAG}" -eq 0 ]; then

  CMD=`returnQSUB_CMD ${STAMP}`
  CMD=${CMD}" <<< '"
  CMD=${CMD}"perl ${PL_SITE_BY_SITE}"
  CMD=${CMD}" -g ${PHASEFILE} "
  CMD=${CMD}" -d ${ORDER_DIR_LIST} "
  CMD=${CMD}" -l ${ORDER_STRAIN_LIST} "
  #if [ "${CONTRAST_MAX}" -gt 0 ]; then
  #  CMD=${CMD}" -c ${CONTRAST_MAX} " 
  #fi
  CMD=${CMD}" -s ${HAP_LIST_OUTDISP} "
  CMD=${CMD}" -r "   # only one difference from the step${STEP}
  CMD=${CMD}"'"
  
  echo ${CMD}
  eval ${CMD}
  if [ $? -ne 0 ]; then 
    echo_fail "Execution error: ${CMD} (step${STEP}) "
  fi
  
  wait_until_finish "${STAMP}"


  if [ ! -s "${COMBINED_RES_DIR}/${OUTF_SITE_STATS}" ]; then
    echo_fail "Error (step${STEP}): ${COMBINED_RES_DIR}/${OUTF_SITE_STATS} doesn't exist or empty "
  fi

  if [ ! -s "${COMBINED_RES_DIR}/${OUTF_SUMMARY_POS}" ]; then
    echo_fail "Error (step${STEP}): ${COMBINED_RES_DIR}/${OUTF_SUMMARY_POS} doesn't exist or empty "
  fi

  if [ `gzip -dc "${COMBINED_RES_DIR}/${OUTF_SUMMARY_TXT}" | wc -l` -le 1 ]; then
    echo_fail "Error (step${STEP}): ${COMBINED_RES_DIR}/${OUTF_SUMMARY_TXT} is empty "
  fi

  if [ ! -s "${COMBINED_RES_DIR}/${OUTF_SUMMARY_RANGE}" ]; then
    echo_fail "Error (step${STEP}): ${COMBINED_RES_DIR}/${OUTF_SUMMARY_RANGE} doesn't exist or empty "
  fi


  echo "The step${STEP} normally finished."

else
  echo "step${STEP} was skipped because all output files are in ${COMBINED_RES_DIR}"
fi

move_log_files "${STAMP}"


#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
# visualization 
#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
STEP=7

get_stamp ${STEP}
#arr_STAMP=("${arr_STAMP[@]}" "${STAMP}")
disp_punctuate ${STEP} ${STAMP}

#
# basic plot (histgram & along the sequemce) of all sites
#
if [ ! -s "${COMBINED_RES_DIR}/${PNG_HIST}" -o ! -s "${COMBINED_RES_DIR}/${PNG_ALONG_SEQ}" ]; then
  CMD="R --vanilla --quiet < ${R_MAIN1} --args ${R_LIB_HEATMAP} ${COMBINED_RES_DIR}/${OUTF_SITE_STATS} > /dev/null 2>&1"
  echo ${CMD}
  eval ${CMD}
  if [ $? -ne 0 ]; then 
    echo_fail "Execution error: ${CMD} (step${STEP}, ${R_MAIN1}) "
  fi
else 
  echo "${R_MAIN1} was skipped because there are already ${COMBINED_RES_DIR}/${PNG_HIST} and ${COMBINED_RES_DIR}/${PNG_HIST}"
fi 

#
# if imputed data are specified,
# plot relation between missing count per site and the distance statistic
#
if [ "${MISSING_POS_IND_FILE}" != "" ]; then
  CMD="R --vanilla --quiet < ${R_CHECK_MISSING_STAT} --args ${MISSING_POS_IND_FILE}  ${COMBINED_RES_DIR}/${OUTF_SITE_STATS} > /dev/null 2>&1"
  echo ${CMD}
  eval ${CMD}
  if [ $? -ne 0 ]; then 
    echo_fail "Execution error: ${CMD} (step${STEP}, ${R_CHECK_MISSING_STAT}) "
  fi
fi

#
# heatmaps of summary sites (not executed by default)
#
MIN=`awk '{print $1}' "${COMBINED_RES_DIR}/${OUTF_SUMMARY_RANGE}"`
MAX=`awk '{print $2}' "${COMBINED_RES_DIR}/${OUTF_SUMMARY_RANGE}"`

echo "If you woud like to have visualization of representative sites, please execute the following commands"

for TYPE in ${arr_summary_type[@]}
do
  if [ -d "${COMBINED_RES_DIR}/${TYPE}" ]; then
    ls ${COMBINED_RES_DIR}/${TYPE}/* > ${COMBINED_RES_DIR}/${TYPE}.list

    NUM_TARGET_POS=`wc -l ${COMBINED_RES_DIR}/${TYPE}.list | awk '{print $1}'`

    ARRAY_S=1
    ARRAY_E=${NUM_TARGET_POS}

    CMD=`returnQSUB_CMD ${STAMP} ${ARRAY_S} ${ARRAY_E}`
    #CMD=${CMD}" -t 1:${NUM_TARGET_POS} "
    CMD=${CMD}" ${SH_R_MAIN2}"
    CMD=${CMD}"  -a ${MIN}"
    CMD=${CMD}"  -b ${MAX}"
    CMD=${CMD}"  -l ${COMBINED_RES_DIR}/${TYPE}.list"
 
    echo ${CMD}
    #QSUB_MSG=`${CMD}`
    if [ $? -ne 0 ]; then 
      echo_fail "Execution error: ${CMD} (step${STEP}, ${SH_R_MAIN2}) "
    fi
    #QSUB_ID=`echo ${QSUB_MSG} | perl -pe 's/ \(.*$//g' | perl -pe 's/^.* //g' | perl -pe 's/\..*$//g'`
  else
    echo_fail "Error: ${COMBINED_RES_DIR}/${TYPE} doesn't exist"
  fi
done

#wait_until_finish "${STAMP}"
#move_log_files "${STAMP}"

#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 

echo "************************************************************** "

date +%Y%m%d_%T
echo "Done. Please look at output files in ${COMBINED_RES_DIR}"


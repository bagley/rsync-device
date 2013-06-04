#!/bin/bash

# changing this will result in having to rehash the devices
checksummer="md5sum"

# checksum each part, then see if it has changed. If so, copy over.
# keep a record of backup's checksum, so each part is only read on copy
# (or would it be better to verify? no, backuppc will do that)

original=
backup=


# where do we store the saved checksums of the backup device?
# comment out to ignore (no saved checksums)
# saved_checksums=/root/saved_checksums

# how small do we break the device up for checking. Smaller is better for
# little changes but may take longer. Larger is better for lots of changes
# and may be faster.
# Changing this will invalidate any currenty saved checksums
mb_per_round=20
notify_every_mb=500

# unset any timeout
unset TMOUT 2>/dev/null

usage() {
  if [ -n "$1" ] ; then
    echo
    echo "$1"
    echo
  fi
cat <<EOF
  Copy a device or file from one location to another, only copying
  the changed areas. Checksums can be cached in a file to allow
  for faster backups.
  
  Yes, it is like rsync, but larger checksums and device support (/dev/sda2)
  
  Usage: ( Options must preceed files/devices. )
  
     `basename $0` [-srnv] <original> <backup>
     
     `basename $0` -c -s /file [-nv] <backup>
  
  Options:
    
    -s FILE      File to save of the checksums of backup device/file.
                 If omitted, checksums are not saved.
                 
    -r NUM       Number of megabytes to check at a time, Smaller
                 is better for little changes, and larger is better
		 for lots of changes. Speed depend on number of
		 changes.  Note that changing this will erase
		 any currently saved checksums. Default is 10.
		 
    -n NUM       Print out a status line every NUM of megabytes
                 checked. Defaults to 500.
		 
    -c           Just check the backup device/file. A checksum file (-s)
                 must be provided, and only one backup can be specified.
		 Check size (-r) is ignored, as the checksum file has the
		 needed size in it.
    
    -v           Show verbose messages (not currently implemented)
    
    -h           Show this help message
    
EOF
  exit 1;
}

# leave blank
check_only=

CMDLINE="$*"
while getopts "s:r:n:cvh" opt ; do
    case $opt in
      s) saved_checksums="$OPTARG" ;;
      v) VERBOSE=1 ;;
      r) mb_per_round="$OPTARG" ;;
      n) notify_every_mb="$OPTARG" ;;
      c) check_only="yes" ;;
      h) usage ;;
      *) usage " Error processing arg: $*";;
    esac
done
shift `expr $OPTIND - 1`


# left args are the files
if [ $# -eq 2 ]  && [ -z "$check_only" ] ; then
  original="$1"
  backup="$2"
   
elif [ $# -eq 1 ] && [ -n "$check_only" ] ; then
  backup="$1"

else
  usage "  Incorrect number of files/devices: $*"

fi

# echo "Got orig:$original back:$backup r:$mb_per_round s:$saved_checksums n:$notify_every_mb c:$check_only"
# exit

# needed so piping command will return 1 with _any_ fail
set -o pipefail

get_sum() {
  device=$1
  skip=$2
  count=$3
  
  checksum="$(dd if=$device skip=$skip count=$count bs=${mb_per_round}M 2>/dev/null | "$checksummer" - | awk '{print $1}')"
  RET=$?
  return $RET
}

copy_section() {
  device_from=$1
  device_to=$2
  skip=$3
  count=$4
  
  dd if=$device_from of=$device_to skip=$skip seek=$skip count=$count bs=${mb_per_round}M 2>/dev/null
}

get_saved_sum() {
  if ! [ -e "$saved_checksums" ] || ! [ -r "$saved_checksums" ] ; then
    return 1
  fi
  section=$1
  checksum_check="$(grep "^$section " "$saved_checksums" | awk '{print $2}')"
  if [ -z "$checksum_check" ] ; then
    return 1
  fi
  checksum=$checksum_check
  return 0
}

save_sum() {
  if ! [ -e "$saved_checksums" ] || ! [ -r "$saved_checksums" ] ; then
    return
  fi
  sum=$1
  section=$2
  # overwite checksum if needed
  SUM_TMP_FILE=$(mktemp /dev/shm/checksum.XXXXXXXXXXXXXXXXX)
  grep -v "^$section " "$saved_checksums" | grep -v "^SECTION SIZE " > "$SUM_TMP_FILE"
  echo "$section $sum" >> "$SUM_TMP_FILE"
  
  echo "SECTION SIZE $mb_per_round" > "$saved_checksums"
  cat "$SUM_TMP_FILE" | sort -n >> "$saved_checksums"
  rm -f "$SUM_TMP_FILE"
}

# not needed with error check
# amount=$(fdisk -l $original 2>/dev/null | grep "^Disk $original" | awk '{print $3}')

# check that devices do exist and are devices and can be dd'd
error() {
  echo $1
  echo "For a list of options, try -h"
  exit 1
}

check_device() {
  if ! [ -e "$1" ] ; then
    error "$1 does not exist"
  elif ! [ -r "$1" ] ; then
    error "Cannot read $1"
  fi
  dd if="$1" count=1 bs=1 >/dev/null 2>&1
  if [ $? -ne 0 ] ; then
    echo "Tried to dd $1, but it did not like it."
    echo -n "Are you sure you want to continue? (N/y) "
    read RESP
    if [ "$RESP" != "y" ] ; then
      exit
    fi
  fi
}

######################
# checks

if [ -z "$check_only" ] ; then
  check_device "$original"
fi

check_device "$backup"


# check if saved checksums file exists and is right section size
if [ -z "$check_only" ] ; then

if [ -n "$saved_checksums" ] ; then
 if ! [ -e "$saved_checksums" ] ; then
  echo "Warning: Saved checksums file $saved_checksums does not exist. File created."
  echo "This is expected for your first run, but not subsequent runs"
  echo
  touch "$saved_checksums" || error "Cannot create checksum file $saved_checksums"

 elif [ "$(head -n 1 "$saved_checksums" | awk '{print $3}')" != "$mb_per_round" ] ; then
  echo "Your saved checksum file is not for this size of breakups."
  echo -n "Proceeding will destroy the saved checksums. Do you want to continue? (N/y) "
  read RESP
  if [ "$RESP" != "y" ] ; then
    exit
  fi
  echo -n > "$saved_checksums"
  echo
 fi
fi

else

  if ! [ -f "$saved_checksums" ] ; then
    error "Could not find saved checksums at $saved_checksums"
  
  fi
  
  # get size
  mb_per_round="$(head -n 1 "$saved_checksums" | awk '{print $3}')"
  
fi
    

### check only ###

if [ -n "$check_only" ] ; then
  echo "Checking $backup, $mb_per_round mb at a time, with notices every $notify_every_mb mb."
  PART=0
  AT_END=0
  notify_every=$(expr $notify_every_mb \/ $mb_per_round)
  notify_timeout=$notify_every
  while [ $AT_END -eq 0 ] ; do
  
    # get backup sum
    get_saved_sum $PART
    checksum_saved=$checksum
    
    # get actual sum
    get_sum $backup $PART 1
    if [ $? -ne 0 ] ; then
       AT_END=$?
       if [ $AT_END -ne 0 ] ; then
         break
       fi
       # LOC1=$(expr $PART \* $mb_per_round)
       # error "Failed to get checksum for section $LOC1 mb"
    fi
    checksum_backup=$checksum
    
    if [ "$checksum_saved" != "$checksum_backup" ] ; then
      LOC1=$(expr $PART \* $mb_per_round)
      LOC2=$(expr $LOC1 + $mb_per_round)
      copy_section $original $backup $PART 1
      echo "ERROR: Data is changed from $LOC1 mb to $LOC2 mb."
      echo
      echo "Saved: $checksum_saved"
      echo "Got:   $checksum_backup"
      echo
      exit 1 #so scripts can decide to do a full check (no -s)
    fi

    # output
    if [ $notify_timeout -le 0 ] ; then
      LOC1=$(expr $PART \* $mb_per_round)
      echo "Checked $LOC1 mb."
      notify_timeout=$notify_every
    else
      notify_timeout=$(expr $notify_timeout - 1)
    fi
    
    # next
    PART=$(expr $PART + 1)

  done
  
  echo "Check successful"
  exit 0
  
fi

    
  


### full copy ###

# time to work
echo "Checking and copying from $original to $backup,"
echo "$mb_per_round mb at a time, with notices every $notify_every_mb mb."
PART=0
AT_END=0
changed=0
notify_every=$(expr $notify_every_mb \/ $mb_per_round)
notify_timeout=$notify_every
while [ $AT_END -eq 0 ] ; do
  
  # get original sum
  get_sum $original $PART 1
  AT_END=$?
  if [ $AT_END -ne 0 ] ; then
    break
  fi
  checksum_original=$checksum
  
  # get backup sum, preferrably from saved list
  get_saved_sum $PART
  if [ $? -ne 0 ] ; then
    get_sum $backup $PART 1
    if [ $? -ne 0 ] ; then
       LOC1=$(expr $PART \* $mb_per_round)
       error "Failed to get checksum for section $LOC1 mb"
    fi
    save_sum $checksum $PART
  fi
  checksum_backup=$checksum
  
  # we replay this to check that the data was copied correctly
  correct=0
  tries=3
  while [ $correct -eq 0 ] && [ $tries -gt 0 ] ; do
  
  # compare it
  if [ "$checksum_original" != "$checksum_backup" ] ; then
    LOC1=$(expr $PART \* $mb_per_round)
    LOC2=$(expr $LOC1 + $mb_per_round)
    copy_section $original $backup $PART 1
    echo "Copied changed data from $LOC1 mb to $LOC2 mb."
    changed=$(expr $changed + 1)
    # get checksum and save it
    get_sum $backup $PART 1
    checksum_backup=$checksum
    save_sum $checksum $PART
    #echo "Original: $checksum_original"
    #echo "Backup:   $checksum_backup"
    tries=$(expr $tries - 1)
  else
    # nothing to copy, so just move on
    correct=1
  fi
  
  done # replay
  if [ $correct -eq 0 ] ; then
    error "Failed to copy above section"
  fi
  
  # output
  if [ $notify_timeout -le 0 ] ; then
    LOC1=$(expr $PART \* $mb_per_round)
    echo "Checked $LOC1 mb."
    notify_timeout=$notify_every
  else
    notify_timeout=$(expr $notify_timeout - 1)
  fi

#  # test - exit after X mb of data
#  TOTAL=$(expr $PART \* $mb_per_round)
#  if [ $TOTAL -ge 1000 ] ; then
#    echo "Finished $TOTAL mb"
#    exit
#  fi

  # next
  PART=$(expr $PART + 1)
  
done

percent=$( expr $changed \* 100 \/ $PART )

echo "Finished. Changed $changed sections out of $PART, or about $percent percent."

//
// computation time:
//   about 2 minutes when N=170, P=80,000
//

#ifdef WIN32
#include "getopt.h"
#else
#include <unistd.h>
#endif

#include <sys/stat.h>
#include <time.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#include <sstream>
#include <iostream>
#include <fstream>
#include <cstdlib>

#include <map>
#include <string>
#include <vector>
#include <iostream>     // cout
#include <algorithm>    // random_shuffle
#include <vector>       // vector
#include <ctime>        // time
#include <cstdlib>      // rand, srand

using namespace std;
//using namespace boost;

static const char * help=
        "\
        Usage: rd [OPTIONS] \n\
            \n\
            Options:\n\
                -h file.hap \n\
                -p outprefix \n\
                -l strainName.list \n\
                -o strainName_dispOrder.list \n\
                -t 1,...,10 (th ordering to be randomized, which is also used to run from the reverse) \n\
                -i 1,...,n  (th i_recipient) \n\
                -s 1 (this value + counter of random ordering => seed of random number generator) \n\
                \n";


// ######################################################################
// global variables
// ######################################################################
const int MAX_BUFFER = 10240; 

// ######################################################################
// util
// ######################################################################
FILE * fopen_wrapper(const char * filename, const char * mode);
void strReplace (string& str, const string& from, const string& to);
string int2string(int number);
void output (string outDir, string outStrainOrder, vector<string>& arr_indName_rnd, 
             int seed, 
             string outprefix, 
             string& header_line345, 
             map<int, string>& hash_strainIndex2hapseq, 
             map<string, int>& hash_strainName2Index,
             int i_recipient);

FILE * fopen_wrapper(const char * filename, const char * mode) {

    FILE * f = fopen(filename, mode);

    if (f == NULL) {
        printf("Failed to open file %s\n", filename);
    }
    return f;
}

void strReplace (string& str, const string& from, const string& to) {
    string::size_type pos = 0;
    while(pos = str.find(from, pos), pos != string::npos) {
        str.replace(pos, from.length(), to);
        pos += to.length();
    }
}

string int2string(int number) {
    stringstream ss;
    ss << number;
    return ss.str();
}

void output (string outDir, string outStrainOrder, vector<string>& arr_indName_rnd, 
             int seed, 
             string outprefix, 
             string& header_line345, 
             map<int, string>& hash_strainIndex2hapseq, 
             map<string, int>& hash_strainName2Index,
             int i_recipient) {

                int strainIndex; // 1-indexed
                //int i_recipient; // 0-indexed
                int i_donor; // 0-indexed
                FILE *fh_out_strainOrder;
                FILE *fh_out_hap;
                char name_recip[512];
                char fname_strainOrder[512];
                char fname_hap[512];

                //for (i_recipient=0; i_recipient<arr_indName_rnd.size(); i_recipient++) { // recipient
                // parallelized for i_recipient
                    string out_recip_hap = "";

                    // the 1st strain
                    if (i_recipient == 0) {

                         // output strainOrder of this ordering
                         sprintf( fname_strainOrder, "%s", outStrainOrder.c_str() ); 
                         fh_out_strainOrder = fopen_wrapper(fname_strainOrder, "w");

                         for (int i=i_recipient; i<arr_indName_rnd.size(); i++) {
                            fprintf(fh_out_strainOrder, "%s\n",arr_indName_rnd[i].c_str());
                         }

                         fclose(fh_out_strainOrder);

                    } else {
                        sprintf( name_recip, "recip%04d", i_recipient+1 ); 
                        out_recip_hap = outDir + "/" + string(name_recip) + "_" + arr_indName_rnd[i_recipient] + ".hap";

                        printf("output %s\n", out_recip_hap.c_str());

                        sprintf( fname_hap, "%s", out_recip_hap.c_str() ); 
                        ofstream ofs(fname_hap);
                        ofs << 0 << endl;
                        ofs << i_recipient+1 << endl;
                        ofs << header_line345 << flush;

                        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
                        // randomized indName 
                        // => strainIndex 
                        // => hash_strainIndex2hapseq[strainIndex] (in the input hap file)
                        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 

                        //
                        // donors for this recipient (0,...,i_recipient-1)
                        //   the first donor in the 6th line of the .hap file is always the same 
                        //
                        for (i_donor=0; i_donor<=i_recipient-1; i_donor++) {
                            strainIndex = hash_strainName2Index[arr_indName_rnd[i_donor]];

                            if (hash_strainIndex2hapseq[strainIndex] == "") {
                                fprintf(stderr, "Error: strainName=%s is not found in hash_strainName2Index\n",
                                    arr_indName_rnd[i_donor].c_str());

                                map<string, int>::iterator p;
                                for (p = hash_strainName2Index.begin(); p != hash_strainName2Index.end(); p++) {
                                    printf("%s\t%d\n", p->first.c_str(), p->second);
                                }
                                exit(1);
                            }
                           ofs << hash_strainIndex2hapseq[strainIndex] << endl;
                        }
                        //
                        // recipient haplotype in the final row
                        //
                        strainIndex = hash_strainName2Index[arr_indName_rnd[i_recipient]];
                        ofs << hash_strainIndex2hapseq[strainIndex] << endl;
                    }

                //}

}


// ######################################################################
// main 
// ######################################################################
int main(int argc, char **argv)
{

    // getopt
    int c;
    bool verbose=false;
    char * hapFile=NULL;
    char * strain_listFile=NULL;
    char * fine_ordering_listFile=NULL;
    int cnt_rnd_order=-1;
    int i_recipient=-1;
    int seed=-1;
    string outprefix = "";

    if (argc==1) {printf("%s",help);exit(0);}
    while ((c = getopt (argc, argv, "h:p:l:o:t:i:s:v")) != -1)
        switch (c)
    {
        case('h'):hapFile=optarg;break;
        case('p'):outprefix=optarg;break;
        case('l'):strain_listFile=optarg;break;
        case('o'):fine_ordering_listFile=optarg;break;
        case('t'):cnt_rnd_order=atoi(optarg);break;
        case('i'):i_recipient=atoi(optarg);break;
        case('s'):seed=atoi(optarg);break;
        case('v'):verbose=true;break;
        case '?':
            if (isprint (optopt))
                fprintf (stderr, "Unknown option `-%c'.\n", optopt);
            else
                fprintf (stderr,
                "Unknown option character `\\x%x'.\n",
                optopt);
            return 1;
        default:
            abort ();
    }

    // 1-indexed => 0-indexed
    i_recipient--;

    //printf("%s\n",dir_ordering_listFile);
    //cout << string(dir_ordering_listFile) << endl;

    //
    // variables
    //
    int i;
    int j;
    int strainIND; // 1-indexed
    int status;
    int cnt_line; // 1-indexed
    FILE *fh;
    char fname[512];
    char name_ordering[512];
    char buffer[MAX_BUFFER];
    char** arr_line = (char**)calloc(1000 , sizeof(char*)); // only to read 2-column small files

    struct stat sb;

    //string outprefix = hapFile;
    //strReplace(outprefix,".hap","");

    vector<string> arr_indName_rnd_eachOrdering; // randomized
    vector<string> arr_indName_reverse_eachOrdering; // randomized and reversed

    string outDir_forward;
    string outDir_reverse;
    string outStrainOrder_forward;
    string outStrainOrder_reverse;

    stringstream ss;
    time_t timer;
    char *stamp;

    string header_line345 = "";
    map<int, string> hash_strainIndex2hapseq; // 1-indexed
    map<string, int> hash_strainName2Index; // 1-indexed

    ifstream input(hapFile);
    string line;

    // ########################################################################################

    srand ( seed + cnt_rnd_order );

    timer = time(NULL); stamp = ctime(&timer); stamp[strlen(stamp)-1] = '\0';
    printf("%s: start\n",stamp);

    //
    // read hap files 
    //   width can be very large, so use getline instead of fgets
    //
    cnt_line = 1;
    while (getline(input, line)) {
        //
        // get line 3,4,5
        // 
        if (3 <= cnt_line && cnt_line <= 5) {
            header_line345 = header_line345 + line + "\n";
            //
            // get hap sequencest
            //
        } else if (5 < cnt_line) {
            hash_strainIndex2hapseq[cnt_line-5] = line;
        }
        cnt_line++;
    }

    //
    // read strain_listFile
    //
    strainIND = 1;
    fh = fopen_wrapper(strain_listFile, "r");
    while (!feof(fh)) {
        if (fgets(buffer, MAX_BUFFER, fh) != NULL) {
            buffer[strlen(buffer) - 1] =  '\0';

            string strainName; 

            *arr_line = strtok(buffer , "\t");
            strainName = string(*arr_line);

            hash_strainName2Index[strainName] = strainIND;
            strainIND++;
        }
    }
    fclose(fh);

    //
    // read fine_ordering_listFile
    //   random orderings are created based on this 
    //
    strainIND = 1;
    fh = fopen_wrapper(fine_ordering_listFile, "r");
    while (!feof(fh)) {
        if (fgets(buffer, MAX_BUFFER, fh) != NULL) {
            buffer[strlen(buffer) - 1] =  '\0';

            string strainName; 

            *arr_line = strtok(buffer , "\t");
            strainName = string(*arr_line);

            arr_indName_rnd_eachOrdering.push_back(strainName);
        }
    }
    fclose(fh);	

    //
    // randomize 
    // 
    random_shuffle ( arr_indName_rnd_eachOrdering.begin(), arr_indName_rnd_eachOrdering.end() );

    //
    // reverse
    //
    arr_indName_reverse_eachOrdering = arr_indName_rnd_eachOrdering;
    reverse( arr_indName_reverse_eachOrdering.begin(), arr_indName_reverse_eachOrdering.end() );

    //
    // output
    //   hap file of each recipient
    //     0
    //     num of donor + recipient haplotypes for the recipient
    //     line 3,4,5
    //
    //     the first haplotype: recipient
    //     other following haplotypes: donors on which the recipient conditions 
    //
    sprintf( name_ordering, "_rnd%02d", cnt_rnd_order ); 
    outDir_forward = outprefix + "_orderedS" + int2string(seed) + string(name_ordering) + "_forward";
    outDir_reverse = outprefix + "_orderedS" + int2string(seed) + string(name_ordering) + "_reverse";

    if (!(stat(outDir_forward.c_str(), &sb) == 0 && S_ISDIR(sb.st_mode))) {
        status = mkdir(outDir_forward.c_str(), S_IRWXU | S_IRWXG | S_IROTH | S_IXOTH);
    }
    if (!(stat(outDir_reverse.c_str(), &sb) == 0 && S_ISDIR(sb.st_mode))) {
        status = mkdir(outDir_reverse.c_str(), S_IRWXU | S_IRWXG | S_IROTH | S_IXOTH);
    }

    outStrainOrder_forward = outDir_forward + ".strainOrder";
    outStrainOrder_reverse = outDir_reverse + ".strainOrder";

#ifdef DEBUG
    for (i=0; i<arr_indName_rnd_eachOrdering.size(); i++) {
        printf("%s\n",arr_indName_rnd_eachOrdering[i].c_str());
    }
#endif

    output(outDir_forward, outStrainOrder_forward, arr_indName_rnd_eachOrdering, 
        seed, outprefix, header_line345, hash_strainIndex2hapseq, hash_strainName2Index, i_recipient);
    output(outDir_reverse, outStrainOrder_reverse, arr_indName_reverse_eachOrdering, 
        seed, outprefix, header_line345, hash_strainIndex2hapseq, hash_strainName2Index, i_recipient);

    //
    // end
    //
    free(arr_line);

    timer = time(NULL); stamp = ctime(&timer); stamp[strlen(stamp)-1] = '\0';
    printf("%s: end\n", stamp);
    //printf("%s: output files are in %s/ and %s/\n", stamp, outDir_forward.c_str(), outDir_reverse.c_str());

    return 0;

}

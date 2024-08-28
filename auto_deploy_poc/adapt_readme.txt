#####################################################################
GENERAL
#####################################################################
Purpose:
Creating actual day0/day1 files from provided template files

Inputs:
- KUBECONFIG variable must be exported before running the script, so script can connect to cluster and collect info!
- In case of geo-red system, SITE2_CONFIG must be exported as well, and point to admin.conf for the second cluster
- Metallb and coredns need to be properly configured on the cluster(s)
- input_dir, containing yaml and xml files which require adaptation. It will usually be populated by get_product_inputs.sh script
- input_template.txt, containing rules for filling day0/day1
- Filename of input template can be overriden by setting this env. variable:
  export VALUES_TEMPLATE_FILE=some_other_input.txt

Outputs:
- cluster_vars.tmp, containing info about cluster IPs and other properties (this is basically set of environment variables)
- This file can be reused by other scripts
- Variables from the file can be referenced anywhere in input_template.txt
- Adapted day0/day1 files in adapted_dir
- Script is removing empty lines and comments from generated files

Execution:
- Just run without parameters
- Add -v flag for verbose output

Additional notes:
- Cluster can have optional "extra-settings" configmap in "jenkins-tools" namespace. Supported parameters (and default values)
  hsm: "false"     #if set to true, CCSM will be deployed with HSM settings
  hss-fe: "false"  #if set to true, EDA2 will be deployed with HSS-FE validator, otherwise with cnHSS validator
  nft: "false"     #if set to true, input_template_nft.txt will be used as default input file. Otherwise, input_template.txt is used
- For CCES, there are 2 day0 templates: mtls-smallmbb-values and mtls-6m-values. Depending on inputs, only one will be adapted, and other will be ignored
- In multi-cluster deployments, if script recognizes there are 2 CCDMs, all CCDM files will be duplicated and renamed, so they can handled separately
  For example, original file:
    eric-ccdm_day1__ericsson-udr_template.xml
  Results with:
    eric-ccdm_day1__SITE1_ericsson-udr_template.xml
    eric-ccdm_day1__SITE2_ericsson-udr_template.xml


#####################################################################
Preparing input_template.txt
#####################################################################
File input_template.txt is being processed sequentially, and rules are applied to files in input_dir.
Basic syntax:
  TARGET=<filename pattern>
  <key1>; <value1>
  <key2>; <value2>
  ...
  <keyN>; <valueN>

Rules are applied for configured target (file pattern), until another target is set
Between key and value we can have arbitrary number of whitespaces
All variables from cluster_vars.tmp can be used when defining rules
Comment lines are allowed

Example:
  TARGET=ccdm*yaml
  storageClass; ${STORAGE_CLASS}
  TARGET=ccsm*yaml
  productType;     CCSM

Special case: if needed, default TARGET logic can be disabled, by setting it to empty value
In such case, target must be specified in every subsequent line. Example:
  TARGET=
  ccsm*nrf*agent; PATH=notification-address.fqdn; ${ausf_5g_sig_FQDN}


#####################################################################
YAML files - supported syntax rules
#####################################################################
Only files with .yaml suffix are taken into account
In YAML parsing, "someString:" in input files is treated as KEY.
VALUE can be any string, e.g. complex yaml block.
If spaces are part of the value, use % to represent them. For newlines, use \n. Example:
  aaa:%bbb\n%%ccc:%dd

----------------------------------------------
keyString; valueString
----------------------------------------------
  All keys matching the input will be set to value. Example:
    enableCrashDumps; true

----------------------------------------------
PATH=path.to.key; valueString
----------------------------------------------
  ONE occurence of specified key path is set to value.
  It's not mandatory to set the path starting from the root element.
  Also, some hops in the path can be skipped. Example:
    PATH=eric-tm-ingress-controller-cr.ingressClass;  eda

  It is also supported to specify YAML array item in path (index starts with 1). Example:
    PATH=eric-ccpc-sbi-traffic-mtls.addresses.1;  1.2.3.4

----------------------------------------------
keyString; -    ||    keyString; --
----------------------------------------------
  This syntax just removes {{ }} placeholder for given key (all matches)
  If there are multiple values {{A|B|C}}, - will set A, -- will set B, --- will set C
    replicaCount; -
    maxReplica; --

----------------------------------------------
-; valueOld=valueNew
----------------------------------------------
  Raw find/replace of any given string (all matches). Key is not provided.
  This is used when other rules cannot achieve needed result. Example:
    -; anyString=anyOtherString

----------------------------------------------
keyString; COMMENT    ||    keyString1_keyString2; COMMENT
----------------------------------------------
  Comment all lines matching given key. Example:
    rackAwarenessMaxSkew; COMMENT

  Also, it is possible to comment everything between keyString1 and keyString2. Example:
    fsGroup_namespace; COMMENT

----------------------------------------------
keyString; UNCOMMENT    ||    keyString1_keyString2; UNCOMMENT
----------------------------------------------
  Unomment all lines matching given key. Example:
    cloudProviderLB; UNCOMMENT

  Also, it is possible to uncomment everything between keyString1 and keyString2. Example:
    https-papi-provisioning_resolution; UNCOMMENT

----------------------------------------------
ROOT; content
----------------------------------------------
  Inserting elemet at root level (outside any existing key). Example:
    ROOT; iam-client-creation:\n%%imageCredentials:\n%%%%registry:\n%%%%%%url:%armdocker.rnd.ericsson.se

----------------------------------------------
CLEANUP_YAML; true
----------------------------------------------
  Special syntax. If this is set for some yaml, script will look for all "orphan" keys and remove them.
  For example, this whole block would be removed:
    eric-act-mutex-handler:
      nodeSelector:
      appArmorProfile:
        type:


#####################################################################
XML files - supported syntax rules
#####################################################################
Only files with .xml suffix are taken into account
In XML parsing, "<someString>" in input files is treated as KEY.
VALUE can be any string, e.g. complex xml block.
If spaces are part of the value, use % to represent them. For newlines, use \n.

----------------------------------------------
keyString; valueString
----------------------------------------------
  All keys matching the input will be set to value.
  It is assumed that start and end tag are in the same line. Example:
    scheme; https

----------------------------------------------
keyString; MARK_BLOCK
----------------------------------------------
  ONE key instance is marked, and it's no longer treated like a key.
  Further operation on this specific instance of the key are not possible (e.g REMOVE_BLOCK)
    own-addresses; MARK_BLOCK

----------------------------------------------
keyString; REMOVE_BLOCK
----------------------------------------------
  Remove all blocks identified by key.
  If all block instance except one need to be removed, use MARK_BLOCK, then REMOVE_BLOCK.
  Example of removal:
    own-addresses; REMOVE_BLOCK

----------------------------------------------
PATH=path.to.key; valueString
----------------------------------------------
  ONE occurence of specified key path is set to value.
  It's not mandatory to set the path starting from the root element.
  Also, some hops in the path can be skipped.
  Once some path is filled, it's marked, and it's no longer treated like a key.
  This example will set first occurence of "instance-id" to "nnrf-nfm-01", and second to "nnrf-nfm-01":
    PATH=service.instance-id;     nnrf-nfm-01
    PATH=service.instance-id;     nnrf-disc-01

----------------------------------------------
-; valueOld=valueNew
----------------------------------------------
  Raw find/replace of any given string (all matches). Key is not provided.
  This is used when other rules cannot achieve needed result. Example:
    -; {{MONTE-ORIGIN-HOST}}=monte.ericsson.se

----------------------------------------------
ONE=keyString; valueString
----------------------------------------------
  ONE occurence of specified key is set to value.
  Once that instance is filled, it's marked, and it's no longer treated like a key. Example:
    ONE=national-address; 31152010002

----------------------------------------------
INSERT_INTO=keyString; valueString
----------------------------------------------
  Insert content inside block specified by keyString.
  Just first match is taken into account. After insert, tag is marked and no longer treated like a key.
    INSERT_INTO=features; <umts-aka><oam-activated>true</oam-activated></umts-aka>

----------------------------------------------
INSERT_AFTER=keyString; valueString
----------------------------------------------
  Insert content after block specified by keyString (after closing tag).
  Just first match is taken into account. After insert, tag is marked and no longer treated like a key.
    INSERT_AFTER=nf-profile; <administrative-state>unlocked</administrative-state>

----------------------------------------------
INSERT_FILE=keyString; ./path/to/file
----------------------------------------------
  Logic is very similar to INSERT_INTO, but content is taken from file.
  So, in this case, file path is value. This is convenient if value would be too big.
  Here is an example:
    INSERT_FILE=ldap-access; ./configurations/ldap_schemas.xml

----------------------------------------------
UNCOMMENT_TAG; all
----------------------------------------------
  Special syntax, currently only supports "all" value
  Used to uncomment all optional tags in xml, like this one:
    <!--
     <name>nudm-uecm</name>
    -->



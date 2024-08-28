pipelineJob('univ_deploy_products') {

    logRotator(-1, 50, 1, -1)
    authorization {
        permission('hudson.model.Item.Read', 'anonymous')
        permission('hudson.model.Item.Read:authenticated')
        permission('hudson.model.Item.Build:authenticated')
        permission('hudson.model.Item.Cancel:authenticated')
        permission('hudson.model.Item.Workspace:authenticated')
    }

    parameters {
        stringParam (
            'GERRIT_BRANCH',
            'master',
            'Branch that will be used to clone Jenkinsfile from 5gcicd/integration repository',
        )
        stringParam (
            'GERRIT_REFSPEC',
            ' ',
            """Refspec for 5gcicd/univ_5g_pipeline repository. This parameter takes prevalence over
            the other parameters. 
            This parameter is also used to clone the Jenkinsfile that will run the job"""
        )
        stringParam (
            'CLOUD',
            'eccd-ans-udm70935',
            'To choose a different cluster from default one.',
        )
        stringParam (
            'CLOUD_PRODUCTS',
            '',
            'Select which products to deploy in first cluster, or LEAVE BLANK TO DEPLOY ALL. Syntax example: "eric-ccrc,eric-eda2". Set "NONE" if nothing needs to be deployed',
        )
        stringParam (
            'CLOUD2',
            '',
            'Set name of the second cluster, if used. Otherwise leave blank.',
        )
        stringParam (
            'CLOUD2_PRODUCTS',
            '',
            'Select which products to deploy in second cluster, or LEAVE BLANK TO DEPLOY ALL. Syntax example: "eric-cces,eric-ccpc". Set "NONE" if nothing needs to be deployed<br><br><br>',
        )
        stringParam (
            'TARGET_EVNFM',
            '',
            'Set EVNFM which will be used for deployment (e.g. evnfm.5g21.eccd-ibd-udm25723.seli.gic.ericsson.se). Leave blank for deployment without EVNFM<br><br><br>',
        )
        stringParam (
            'JENKINS_GERRIT_BRANCH',
            'master',
            'Branch that will be used to clone Jenkinsfile from 5gcicd/univ_5g_pipeline repository',
        )
        stringParam (
            'JENKINS_GERRIT_REFSPEC',
            '${GERRIT_REFSPEC}',
            """Refspec for 5gcicd/integration repository. This parameter takes prevalence over
            the other parameters.
            This parameter is also used to clone the Jenkinsfile that will run the job"""
        )
        stringParam (
            'CCRC_REPO',
            'https://armdocker.rnd.ericsson.se/artifactory/proj-ccrc-helm-local/tmp/ccrc-csar',
            'CSAR package repository URL for CCRC',
        )
        stringParam (
            'CCSM_REPO',
            'https://arm.seli.gic.ericsson.se/artifactory/proj-hss-docker-global/proj_hss/5g/releases/csar',
            'CSAR package repository URL for CCSM',
        )
        stringParam (
            'CCDM_REPO',
            'https://arm.seli.gic.ericsson.se/artifactory/proj-5g-ccdm-released-generic-local/CCDM',
            'CSAR package repository URL for CCDM',
        )
        stringParam (
            'CCPC_REPO',
            'https://arm.seli.gic.ericsson.se/artifactory/proj-5g-ccpc-ci-internal-generic-local/ccpc-cle0',
            'CSAR package repository URL for CCPC',
        )
        stringParam (
            'CCES_REPO',
            'https://arm.seli.gic.ericsson.se/artifactory/proj-cces-dev-generic-local/csar/cces',
            'CSAR package repository URL for CCES',
        )
        stringParam (
            'EDA2_REPO',
            'https://arm.seli.gic.ericsson.se/artifactory/proj-activation-poc-helm-local/activation/verified',
            'CSAR package repository URL for EDA2',
        )
        stringParam (
            'CCSM_USE_MASTER',
            'false',
            'Include subdirectory master/ for CCSM CSAR repository URL',
        )
        stringParam (
            'ALWAYS_REINSTALL',
            'true',
            'Reinstall selected products even if they are on wanted version and healthy',
        )
        stringParam (
            'DRY_RUN',
            'false',
            'day0/day1 incompatibility detection parameter',
        )
    }

    definition {
        cpsScm {
            scm {
                git {
                    remote {
                        name('origin')
                        url('https://${COMMON_GERRIT_URL}/a/5gcicd/univ-5g-pipeline')
                        credentials('userpwd-adp')
                        refspec('${JENKINS_GERRIT_REFSPEC}')
                    }
                    branch('${JENKINS_GERRIT_BRANCH}')
                    extensions {
                        wipeOutWorkspace()
                        choosingStrategy {
                            gerritTrigger()
                        }
                    }
                }
                scriptPath('cicd/Jenkinsfile.deploy')
            }
        }
    }
}

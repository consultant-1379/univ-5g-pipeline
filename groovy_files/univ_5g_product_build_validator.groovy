pipelineJob('univ_HSS_build_validator') {

    properties {
        disableConcurrentBuilds()
    }


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
            '',
            """Refspec for 5gcicd/univ_5g_pipeline repository. This parameter takes prevalence over
            the other parameters.
            This parameter is also used to clone the Jenkinsfile that will run the job"""
        )
        stringParam (
            'TG',
            'seliius06917',
            'Choose a TG where job will be started.<br><br>',
        )
        stringParam (
            'HSS_FE_VERSION',
            '',
            'Specify HSS-FE version, e.g. in case of csar_package_1_38_3_persistent.csar, set 1_38_3. Leave empty to skip building HSS-FE validator',
        )
        stringParam (
            'CCSM_VERSION',
            '',
            'Specify CCSM CSAR package version. E.g. in case of Ericsson.CCSM.CXP9037722_1_21_5_11.csar, set 1_21_5_11. Leave empty to skip building cnHSS validator',
        )
        stringParam (
            'TAG_LATEST',
            'false',
            'Specify if additional "latest" tag will be added to images being built. False by default',
        )
        stringParam (
            'SDK_LINK',
            'https://arm.seli.gic.ericsson.se/artifactory/proj-ema-release-local/com/ericsson/EDA2_SDK_CA/9.3.9/EDA2_SDK_CA-9.3.9.tar.gz',
            'Link of EDA2 SDK tool package. Default value should be fine. If needed, provide different link.',
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
                scriptPath('cicd/Jenkinsfile.build_validator')
            }
        }
    }
}

pipelineJob('univ-nft-test-products') {

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
            'GERRIT_REFSPEC',
            '',
            'Refspec that will clone 5gcicd/univ-5g-pipeline repository',
        )
        stringParam (
            'GERRIT_BRANCH',
            'master',
            'Branch that will be used to clone 5gcicd/univ-5g-pipeline repository',
        )
        stringParam (
            'CLOUD',
            'eccd-ans-udm70935',
            'To choose a different cluster from default one.',
        )
        stringParam (
            'TG',
            '',
            'Choose a TG where NFT will be started.<br><br>',
        )
        stringParam (
            'SUITE_FILE',
            'udm5g-nonfunctional-testcases/src/main/resources/suites/nonFunctionalTest/StableTestSuite.yaml',
            'To choose a different suite file to run tescases.<br><br>',
        )
        stringParam (
            'AUTOMATION_TESTCASES_DOCKER_TAG',
            'latest',
            'To choose a different docker image to run testcases<br><br>',
        )
        stringParam (
            'CLIENT_ID',
            '',
            'Client id used getting MAPI token'
        )
        stringParam (
            'CLIENT_SECRET',
            '',
            'Client secret used for getting MAPI token'
        )
        stringParam (
            'CCSM_CVE_MIX_RATE',
            '100',
            'set rate for CCSM_CVE_MIX traffic'
        )
        stringParam (
            'XRAY_ID',
            '',
            'ID of JIRA ticket to export test result'
        )
        booleanParam(
            'JCAT_DEBUG',
            false,
            'Sets JCAT logging level to debug'
        )
        stringParam (
            'JENKINS_GERRIT_BRANCH',
            'master',
            'Branch that will be used to clone Jenkinsfile from 5gcicd/univ-5g-pipeline repository',
        )
        stringParam (
            'JENKINS_GERRIT_REFSPEC',
            '${GERRIT_REFSPEC}',
            '''"Refspec for 5gcicd/univ-5g-pipeline repository. This parameter takes prevalence over
            the other parameters. 
            This parameter is also used to clone the Jenkinsfile that will run the job'''
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
                scriptPath('cicd/Jenkinsfile.nft_test')
            }
        }
    }
}


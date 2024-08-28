pipelineJob('univ-notify-products') {
    properties {
        disableConcurrentBuilds()
    }
    logRotator(-1, 15, 1, -1)
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
            "Branch that will be used to clone Jenkinsfile from 5gcicd/integration repository",
        )
        stringParam (
            'GERRIT_REFSPEC',
            ' ',
            """Refspec for 5gcicd/integration repository. This parameter takes prevalence over
            the other parameters.
            This parameter is also used to clone the Jenkinsfile that will run the job"""
        )
        stringParam (
            'TESTS_RESULT',
            'FAIL',
            'This parameter show result of testing CCXX charts and control whether Gerrit vote will be -1/+1'
        )
	stringParam (
            'DEPLOY_RESULT',
            'FAIL',
            'This parameter show result of verifying day0/day1 files from CCXX charts'
        )
        stringParam (
            'CCDM',
            'FAIL',
            'This parameter show result of ccdm deployment and control whether Gerrit vote will be -1/+1'
        )
        stringParam (
            'CCSM',
            'FAIL',
            'This parameter show result of ccsm deployment and control whether Gerrit vote will be -1/+1'
        )
        stringParam (
            'CCRC',
            'FAIL',
            'This parameter show result of ccrc deployment and control whether Gerrit vote will be -1/+1'
        )
        stringParam (
            'CCES',
            'FAIL',
            'This parameter show result of cces deployment and control whether Gerrit vote will be -1/+1'
        )
        stringParam (
            'CCPC',
            'FAIL',
            'This parameter show result of ccpc deployment and control whether Gerrit vote will be -1/+1'
        )
        stringParam (
            'EDA2',
            'FAIL',
            'This parameter show result of eda2 deployment and control whether Gerrit vote will be -1/+1'
        )
        stringParam (
            'ARTIFACTS',
            '',
            'This parameter show us if artifacts exist or not'
        )
        stringParam (
            'DRY_RUN',
            '',
            'This parameter enable/disable verifying of day0/day1 files from CCXX charts'
        )
        stringParam (
            'SPINNAKER_URL',
            '',
            'Url pointing to the spinnaker pipeline being executed'
        )
        stringParam (
            'EMAIL_NOTIFY',
            '',
            'Comma separated values of email address to recieve notification.'
        )
        stringParam (
            'TEST_PASSRATE',
            '',
            'Show statistic of test execution'
        )
        stringParam (
            'JENKINS_GERRIT_BRANCH',
            'master',
            "Branch that will be used to clone Jenkinsfile from 5gcicd/integration repository",
        )
        stringParam (
            'JENKINS_GERRIT_REFSPEC',
            '${GERRIT_REFSPEC}',
            """Refspec for 5gcicd/integration repository. This parameter takes prevalence over
            the other parameters.
            This parameter is also used to clone the Jenkinsfile that will run the job"""
        )
        stringParam (
            'XRAY_ID',
            '',
            'ID of JIRA ticket to export test result'
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
                scriptPath('cicd/Jenkinsfile.notify')
            }
        }
    }
}

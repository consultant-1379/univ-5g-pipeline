pipelineJob('univ-create-xray') {
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
            'CREATE_XRAY',
            'false',
            'Enable/disable creation of XRAY JIRA test execution'
        )
        stringParam (
            'PACKAGES_VERSION',
            '',
            'List of CSAR packages'
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
            'CLOUD',
            '',
            'To choose a different cluster from default one.'
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
                scriptPath('cicd/Jenkinsfile.create_xray')
            }
        }
    }
}

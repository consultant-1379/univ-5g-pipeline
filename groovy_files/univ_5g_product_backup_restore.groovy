pipelineJob('univ_CCDM_backup_restore') {

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
            'CLOUD2',
            '',
            'Set name of the second cluster, if used. Otherwise leave blank.',
        )
        stringParam (
            'BACKUP_LOCATION',
            '',
            'Location on TG where backup is stored, e.g. 10.158.165.50:22/proj/udm_univ/5G_integration/Jenkins_NFT/ccdm-data/test-backup-2023-07-24T07:30:21.610742Z.tar.gz',
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
                scriptPath('cicd/Jenkinsfile.backup_restore')
            }
        }
    }
}

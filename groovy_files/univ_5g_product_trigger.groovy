pipelineJob('univ-trigger-products') {

    properties {
        disableConcurrentBuilds()
        pipelineTriggers {
            triggers {
                gerrit {
                    triggerOnEvents {
                        commentAddedContains {
                            commentAddedCommentContains('(?<!-)verify-univ-5g-pipeline')
                        }
                        changeMerged()
                    }
                    gerritProjects {
                        gerritProject {
                            disableStrictForbiddenFileVerification(false)
                            compareType('PLAIN')
                            pattern('5gcicd/univ-5g-pipeline')
                            branches {
                                branch {
                                    compareType('ANT')
                                    pattern('**')
                                }
                            }
                        }
                    }
                    gerritBuildSuccessfulVerifiedValue(0)
                    gerritBuildSuccessfulCodeReviewValue(0)
                    serverName('adp')
                    commentTextParameterMode('PLAIN')
                }
            }
        }
    }

    logRotator(-1, 15, 1, -1)

    authorization {
        permission('hudson.model.Item.Read', 'anonymous')
        permission('hudson.model.Item.Read:authenticated')
        permission('hudson.model.Item.Build:authenticated')
        permission('hudson.model.Item.Cancel:authenticated')
        permission('hudson.model.Item.Workspace:authenticated')
    }

    definition {
        cpsScm {
            scm {
                git {
                    remote {
                        name('origin')
                        url('https://${COMMON_GERRIT_URL}/a/5gcicd/univ-5g-pipeline')
                        credentials('userpwd-adp')
                        refspec('${GERRIT_REFSPEC}')
                    }
                    branch('${GERRIT_BRANCH}')
                    extensions {
                        wipeOutWorkspace()
                        choosingStrategy {
                            gerritTrigger()
                        }
                    }
                }
                scriptPath('cicd/Jenkinsfile.trigger')
            }
        }
    }
}

node("default-jenkins-slave") {
    stage('Write artifacts') {

        def VERIFY = "False"

        def _gerrit_comment = env.GERRIT_EVENT_COMMENT_TEXT.toString().toLowerCase()

        if ( env.GERRIT_REFSPEC != "master" && env.GERRIT_EVENT_TYPE != null) {

            if (_gerrit_comment.contains("verify-univ-5g-pipeline+1")) {
                VERIFY = "True"
            }

            writeFile(file: 'artifact.properties', text:
                "GERRIT_REFSPEC=${env.GERRIT_REFSPEC}\n" +
                "GERRIT_EVENT_TYPE=${env.GERRIT_EVENT_TYPE}\n" +
                "GERRIT_PATCHSET_REVISION=${params.GERRIT_PATCHSET_REVISION}\n" +
                "GERRIT_BRANCH=${params.GERRIT_BRANCH}\n" +
                "VERIFY=${VERIFY.toString()}\n"
            )

            archiveArtifacts allowEmptyArchive: true, artifacts: 'artifact.properties', onlyIfSuccessful: true
        }
    }
}


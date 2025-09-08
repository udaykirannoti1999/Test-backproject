pipeline {
    agent any
    stages {
        stage('Restore DB') {
            steps {
                sh """
                ./restore_db.sh 
                """
            }
        }
    }
}

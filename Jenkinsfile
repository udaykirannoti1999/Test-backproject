pipeline {
    agent any
    stages {
        stage('Restore DB') {
            steps {
                sh """
                chmod +x restore_db.sh
                ./restore_db.sh
                """
            }
        }
    }
}


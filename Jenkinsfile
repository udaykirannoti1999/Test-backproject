pipeline {
    agent any
    parameters {
        string(name: 'DB_INSTANCE_IDENTIFIER', defaultValue: 'back-upstore', description: 'RDS DB Identifier for DR restore')
    }
    stages {
        stage('Restore DB') {
            steps {
                sh """
                chmod +x restore_db.sh
                ./restore_db.sh ${params.DB_INSTANCE_IDENTIFIER}
                """
            }
        }
    }
}


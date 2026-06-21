import os
from flask import Flask, render_template, request, redirect, url_for
import boto3
import pymysql

app = Flask(__name__)

# Initialize AWS and Database Configuration Constants
S3_CLIENT = boto3.client('s3', region_name='us-east-1')
BUCKET_NAME = "user-pictures-bucket-20260621053341019000000003"

DB_CONFIG = {
    'host': "terraform-20260621053411652700000008.coda8u6gguh0.us-east-1.rds.amazonaws.com",
    'user': "admin",
    'password': "SuperSecurePassword123!",
    'database': "picturedb",
    'cursorclass': pymysql.cursors.DictCursor
}

def get_db_connection():
    return pymysql.connect(**DB_CONFIG)

@app.route('/')
def index():
    """Fetches all history images logged in RDS metadata to build the thumbnails grid."""
    connection = get_db_connection()
    try:
        with connection.cursor() as cursor:
         # Grab history from oldest to newest
          cursor.execute("SELECT file_name, s3_url, upload_date, user_id, file_size_kb FROM user_images ORDER BY upload_date DESC")
          images = cursor.fetchall()
    finally:
        connection.close()

    return render_template('index.html', images=images)

@app.route('/upload', methods=['POST'])
def upload():
    """Processes incoming browser upload files directly into S3 and updates RDS."""
    if 'image_file' not in request.files:
        return redirect(url_for('index'))
    
    file = request.files['image_file']
    if file.filename == '':
        return redirect(url_for('index'))

    raw_image_data = file.read()
    file_size_kb = round(len(raw_image_data) / 1024, 2)
    file_name = file.filename
    user_id = "default_user" # Simulated user context identifier

    try:
        # Step A: Push object securely onto S3 storage layer
        S3_CLIENT.put_object(
            Bucket=BUCKET_NAME,
            Key=file_name,
            Body=raw_image_data,
            ContentType=file.content_type
        )
        
        # Step B: Generate immutable static storage link
        s3_url = f"https://{BUCKET_NAME}.s3.amazonaws.com/{file_name}"
        
        # Step C: Log Metadata inside RDS Instance Table
        connection = get_db_connection()
        try:
            with connection.cursor() as cursor:
             sql = "INSERT INTO user_images (user_id, file_name, s3_url, file_size_kb) VALUES (%s, %s, %s, %s)"
             cursor.execute(sql, (user_id, file_name, s3_url, file_size_kb))
             connection.commit()
        finally:
            connection.close()

    except Exception as e:
        print(f"Operational Execution Fault Error: {str(e)}")

    return redirect(url_for('index'))

if __name__ == '__main__':
    # Binds on default web framework listener port
    app.run(host='0.0.0.0', port=80, debug=True)
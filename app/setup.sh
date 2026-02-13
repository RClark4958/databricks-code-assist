#!/bin/bash

# Create directory structure
mkdir -p app/frontend/public
mkdir -p app/frontend/src/components
mkdir -p app/frontend/src/pages
mkdir -p app/frontend/src/assets
mkdir -p app/backend

echo "Directory structure created successfully!"

# Setup backend
cd app/backend
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
echo "Backend dependencies installed!"

# Setup frontend
cd ../frontend
npm install
echo "Frontend dependencies installed!"

echo "Setup complete! You can now run the application."
echo "To start the backend: cd app/backend && python main.py"
echo "To start the frontend: cd app/frontend && npm start"

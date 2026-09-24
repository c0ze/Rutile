Rails.application.routes.draw do
  resources :users, only: %i[show create] do
    get :lookup, on: :collection, constraints: ->(request) { request.query_parameters["email"].present? }
  end
  resources :posts do
    resources :comments, only: %i[index create]
  end

  get "up" => "rails/health#show", as: :rails_health_check
end

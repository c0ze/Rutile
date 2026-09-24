Rails.application.routes.draw do
  resources :users, only: %i[show create]
  resources :projects do
    post :archive, on: :member
    resources :tasks, shallow: true do
      patch :complete, on: :member
    end
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
